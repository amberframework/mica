module Mica::Regex
  # Compiles *pattern* while the application builds and returns a
  # `StaticPattern` whose tables are read-only data in the binary, at the
  # narrowest integer width the pattern allows. Its searches allocate
  # nothing: the tables are `Slice.literal`s and the capture pass keeps
  # its scratch space in a fixed-size `StaticArray` on the stack. Each
  # search checks the work budget and deadline before every read, as the
  # runtime engine does.
  #
  # *pattern* is a regex literal (its `i`, `m` and `x` flags apply, `m`
  # with Crystal's meaning, `Multiline | DotAll`) or a string literal (with
  # *ignore_case* for `i`; other flags go inline, `(?m)`); it must be known
  # when the application builds. A pattern whose automaton is
  # too large to hold statically (see `Static::BuildTheTables`) becomes a
  # `StaticFallback` on the runtime engine, and the compiler prints a note
  # saying why.
  #
  # ```
  # ROUTE_ID = Mica::Regex.static(/\A\d+\z/)
  # ROUTE_ID.matches?("2026") # => true
  # ```
  macro static(pattern, *, ignore_case = false)
    {% if pattern.is_a?(RegexLiteral) %}
      {% source = pattern.source %}
      {% options = 0 %}
      {% for flag in pattern.options %}
        {% if flag == :i %}{% options = options + 1 %}{% end %}
        {% if flag == :m %}{% options = options + 6 %}{% end %}
        {% if flag == :x %}{% options = options + 8 %}{% end %}
      {% end %}
    {% elsif pattern.is_a?(StringLiteral) %}
      {% source = pattern %}
      {% options = ignore_case ? 1 : 0 %}
    {% else %}
      {% pattern.raise "Mica::Regex.static needs a regex or string literal known when the application builds" %}
    {% end %}
    {% output = run("./static/emit_static_pattern", source, options).stringify.split("%%\n") %}
    {% note = output[0].strip %}
    {% if note != "" %}{% puts note %}{% end %}
    {{ output[1].id }}
  end

  # A match's byte span.
  record StaticSpan, byte_begin : Int32, byte_end : Int32 do
    # The match's length in bytes.
    def bytesize : Int32
      byte_end - byte_begin
    end
  end

  # The groups of one match, read from the caller's stack (see
  # `StaticPattern#search_groups`); valid only inside the block it is
  # yielded to. Reading a group's text allocates that `String`, nothing
  # else does.
  struct StaticGroups
    getter haystack : String

    def initialize(@haystack : String, @slots : Slice(Int32))
    end

    # The number of groups, group 0 (the whole match) included.
    def size : Int32
      @slots.size // 2
    end

    # True when group *group* took part in the match.
    def matched?(group : Int32) : Bool
      0 <= group < size && @slots[group * 2] >= 0
    end

    # The byte where group *group* begins, or -1 when it did not take part.
    def byte_begin(group : Int32) : Int32
      @slots[group * 2]
    end

    # The byte where group *group* ends, or -1 when it did not take part.
    def byte_end(group : Int32) : Int32
      @slots[group * 2 + 1]
    end

    # The text of group *group*, or nil when it did not take part.
    def []?(group : Int32) : String?
      return nil unless matched?(group)
      @haystack.byte_slice(byte_begin(group), byte_end(group) - byte_begin(group))
    end
  end

  # The work budget and deadline of one static search call. Its counters
  # live in the caller's stack frame (`counters`, three `Int64`: the
  # operations so far, the next checkpoint and the allowance), so the meter
  # is a plain value that copies freely and allocates nothing.
  struct StaticMeter
    @timeout : Time::Span?
    @started : Time::Instant?

    def initialize(@counters : Pointer(Int64), limits : SearchLimits, state_count : Int32, haystack_bytes : Int32,
                   @timeout : Time::Span?)
      @started = @timeout ? Time.instant : nil
      @counters[0] = 0_i64
      @counters[2] = limits.work_budget(state_count, @timeout).allowance(haystack_bytes.to_i64)
      @counters[1] = next_checkpoint
    end

    # The operations charged so far.
    def operations : Int64
      @counters[0]
    end

    # Raises `Mica::DeadlineExceededError` when the deadline has passed.
    def enforce_deadline(at : Int32) : Nil
      raise_deadline(at) if deadline_passed?
    end

    # Charges *count* operations; raises when the allowance or the deadline
    # is exceeded.
    @[AlwaysInline]
    def charge(count : Int32, at : Int32) : Nil
      operations = @counters[0] &+ count
      @counters[0] = operations
      exceeded(at) if operations > @counters[1]
    end

    # How many of the next *wanted* operations may be made before the
    # meter must be consulted again: at least one, or it raises.
    @[AlwaysInline]
    def readable(wanted : Int32, at : Int32) : Int32
      return 0 if wanted <= 0
      room = @counters[1] - @counters[0]
      if room <= 0
        exceeded(at)
        room = @counters[1] - @counters[0]
        raise Mica::Error.new("internal error: the static meter allowed nothing") if room <= 0
      end
      room < wanted ? room.to_i32 : wanted
    end

    private def exceeded(at : Int32) : Nil
      allowance = @counters[2]
      if @counters[0] > allowance
        raise SearchLimitError.new("max_work", allowance, "A search of #{@counters[0]} operations",
          Core::Position.new(at.to_i64))
      end
      raise_deadline(at) if deadline_passed?
      @counters[1] = next_checkpoint
    end

    private def deadline_passed? : Bool
      timeout = @timeout
      started = @started
      return false unless timeout && started
      Time.instant - started >= timeout
    end

    private def raise_deadline(at : Int32) : NoReturn
      started = @started || Time.instant
      elapsed = Time.instant - started
      raise Mica::DeadlineExceededError.new("Deadline exceeded while searching", Core::Position.new(at.to_i64), elapsed)
    end

    private def next_checkpoint : Int64
      checkpoint = @counters[2]
      if @timeout
        clock = @counters[0] &+ Core::WorkMeter::CLOCK_INTERVAL
        checkpoint = clock if clock < checkpoint
      end
      checkpoint
    end
  end

  # Skips runs of bytes that leave an accelerated DFA state where it is
  # (see `Static::BuildTheTables`). A state's code is one of:
  #
  # - `SKIP_ASCII`: every ASCII byte loops back, so the scan stops at the
  #   first non-ASCII byte (eight bytes at a time);
  # - a byte value 0 to 255: only that byte leaves, found with `memchr`
  #   going forward;
  # - `WORDWISE` with up to `MAX_SCAN_BYTES` ASCII bytes (and
  #   `STOPS_AT_NON_ASCII` when non-ASCII bytes leave too): a scan eight
  #   bytes at a time for any of them.
  #
  # Stopping early is always safe (the DFA reads the byte), so the scans
  # stop at a byte that might leave the state, never past one.
  module StaticByteScan
    SKIP_ASCII         = -1
    WORDWISE           = 1 << 30
    STOPS_AT_NON_ASCII = 1 << 26
    MAX_SCAN_BYTES     =                      3
    ONES               = 0x0101010101010101_u64
    HIGH_BITS          = 0x8080808080808080_u64
    LOW_SEVEN_BITS     = 0x7F7F7F7F7F7F7F7F_u64

    # The code of a word-at-a-time scan for *list_of_bytes* (ASCII).
    def self.encode(list_of_bytes : Array(Int32), stops_at_non_ascii : Bool) : Int32
      code = WORDWISE | (list_of_bytes.size << 24)
      code |= STOPS_AT_NON_ASCII if stops_at_non_ascii
      list_of_bytes.each_with_index { |byte, index| code |= byte << (8 * index) }
      code
    end

    # The first position in *at*...*stop* holding a byte that *code* stops
    # at, or *stop*.
    @[AlwaysInline]
    def self.forward(bytes : Bytes, at : Int32, stop : Int32, code : Int32) : Int32
      return Core::ByteScan.skip_ascii(bytes, at, stop) if code == SKIP_ASCII
      if code < 256
        found = bytes[at, stop - at].index(code.to_u8)
        return found ? at + found : stop
      end
      pointer = bytes.to_unsafe
      while at + 8 <= stop
        flags = stops_in((pointer + at).as(Pointer(UInt64)).value, code)
        return at + flags.trailing_zeros_count // 8 if flags != 0
        at += 8
      end
      while at < stop && !stops_at?(pointer[at], code)
        at += 1
      end
      at
    end

    # Going backward from *at* to no lower than *stop*: the position just
    # after the last byte before *at* that *code* stops at, or *stop*.
    @[AlwaysInline]
    def self.backward(bytes : Bytes, at : Int32, stop : Int32, code : Int32) : Int32
      pointer = bytes.to_unsafe
      while at - 8 >= stop
        flags = stops_in((pointer + at - 8).as(Pointer(UInt64)).value, code)
        return at - flags.leading_zeros_count // 8 if flags != 0
        at -= 8
      end
      while at > stop && !stops_at?(pointer[at - 1], code)
        at -= 1
      end
      at
    end

    # The high bit of each byte of *word* that *code* stops at (exact, so
    # either end of the flags can be read).
    @[AlwaysInline]
    private def self.stops_in(word : UInt64, code : Int32) : UInt64
      flags = code == SKIP_ASCII || code & STOPS_AT_NON_ASCII != 0 ? word & HIGH_BITS : 0_u64
      return flags if code == SKIP_ASCII
      count = code < 256 ? 1 : (code >> 24) & 3
      count.times do |index|
        byte = code < 256 ? code : (code >> (8 * index)) & 0xFF
        difference = word ^ (ONES &* byte.to_u64)
        # Exact zero-byte flags: high bit set where the byte is zero.
        flags |= ~(((difference & LOW_SEVEN_BITS) &+ LOW_SEVEN_BITS) | difference | LOW_SEVEN_BITS)
      end
      flags
    end

    @[AlwaysInline]
    private def self.stops_at?(byte : UInt8, code : Int32) : Bool
      return byte >= 0x80 if code == SKIP_ASCII
      return byte == code if code < 256
      return true if byte >= 0x80 && code & STOPS_AT_NON_ASCII != 0
      count = (code >> 24) & 3
      count.times { |index| return true if byte == (code >> (8 * index)) & 0xFF }
      false
    end
  end

  # One direction's complete DFA (see `Static::DirectionTables`), its
  # entries `T`, the narrowest unsigned integer that holds them.
  struct StaticDirection(T)
    getter stride : Int32
    getter relevant_flags : Int32
    getter context_mask : Int32
    getter special_limit : Int32
    getter accel_limit : Int32
    getter table : Slice(T)
    getter starts : Slice(T)
    getter accel_bytes : Slice(Int32)

    def initialize(*, @stride : Int32, @relevant_flags : Int32, @context_mask : Int32, @special_limit : Int32,
                   @accel_limit : Int32, @table : Slice(T), @starts : Slice(T), @accel_bytes : Slice(Int32))
    end

    # The index into `starts` for state flags *flags*: the bits of
    # `context_mask` packed down, so the table has one entry per
    # combination the DFA can tell apart.
    @[AlwaysInline]
    def start_index(flags : Int32) : Int32
      mask = @context_mask
      index = 0
      bit = 0
      while mask != 0
        lowest = mask & -mask
        index |= 1 << bit if flags & lowest != 0
        bit += 1
        mask &= mask - 1
      end
      index
    end
  end

  # The NFA the capture pass runs (see `Static::NfaTables`), its state
  # numbers `T`.
  struct StaticProgram(T)
    getter start_state : Int32
    getter kinds : Slice(UInt8)
    getter lows : Slice(UInt8)
    getter highs : Slice(UInt8)
    getter next_states : Slice(T)
    getter alternates : Slice(T)
    getter arguments : Slice(T)
    getter sparse_lows : Slice(UInt8)
    getter sparse_highs : Slice(UInt8)
    getter sparse_targets : Slice(T)

    def initialize(*, @start_state : Int32, @kinds : Slice(UInt8), @lows : Slice(UInt8), @highs : Slice(UInt8),
                   @next_states : Slice(T), @alternates : Slice(T), @arguments : Slice(T),
                   @sparse_lows : Slice(UInt8), @sparse_highs : Slice(UInt8), @sparse_targets : Slice(T))
    end

    # The program of a pattern without groups: its capture pass never runs.
    def self.empty : self
      new(start_state: 0, kinds: Slice(UInt8).empty, lows: Slice(UInt8).empty, highs: Slice(UInt8).empty,
        next_states: Slice(T).empty, alternates: Slice(T).empty, arguments: Slice(T).empty,
        sparse_lows: Slice(UInt8).empty, sparse_highs: Slice(UInt8).empty, sparse_targets: Slice(T).empty)
    end

    # The number of states.
    def size : Int32
      @kinds.size
    end

    # The target of Sparse state *state* on *byte*, or -1 (binary search
    # over its sorted, disjoint ranges).
    @[AlwaysInline]
    def sparse_target(state : Int32, byte : UInt8) : Int32
      low = @arguments.unsafe_fetch(state).to_i32
      high = low + @alternates.unsafe_fetch(state).to_i32
      while low < high
        middle = (low + high) >> 1
        if @sparse_highs.unsafe_fetch(middle) < byte
          low = middle + 1
        elsif @sparse_lows.unsafe_fetch(middle) > byte
          high = middle
        else
          return @sparse_targets.unsafe_fetch(middle).to_i32
        end
      end
      -1
    end
  end

  # The one-pass DFA a static pattern's capture pass reads first (see
  # `OnePassDFA#captures` and `Static::OnePassTables`).
  struct StaticOnePass
    # The most bytes read between charges.
    CHUNK_BYTES = 4096

    getter class_count : Int32
    getter steps : Slice(Int32)
    getter cells : Slice(Int32)
    getter match_edges : Slice(Int32)
    getter edge_slots : Slice(UInt64)
    getter edge_looks : Slice(UInt32)
    getter ascii_loops : Slice(UInt8)

    def initialize(*, @class_count : Int32, @steps : Slice(Int32), @cells : Slice(Int32), @match_edges : Slice(Int32),
                   @edge_slots : Slice(UInt64), @edge_looks : Slice(UInt32), @ascii_loops : Slice(UInt8))
    end

    # The one-pass DFA of a pattern that has none.
    def self.empty : self
      new(class_count: 1, steps: Slice(Int32).empty, cells: Slice(Int32).empty, match_edges: Slice(Int32).empty,
        edge_slots: Slice(UInt64).empty, edge_looks: Slice(UInt32).empty, ascii_loops: Slice(UInt8).empty)
    end

    # True when the pattern has a one-pass DFA.
    def present? : Bool
      !@steps.empty?
    end

    # Writes the groups of the match *start*...*finish* into the
    # *slot_count* words at *slots*; returns false when no path reads the
    # span (the caller then runs the Pike VM).
    def captures(bytes : Bytes, start : Int32, finish : Int32, search_start : Int32, classes : Pointer(UInt8),
                 slots : Pointer(Int32), slot_count : Int32, meter : StaticMeter) : Bool
      slot_count.times { |index| slots[index] = -1 }
      steps = @steps.to_unsafe
      row = 0
      at = start
      charged = start
      allowed_end = start
      while at < finish
        if at >= allowed_end
          meter.charge(at - charged, at)
          charged = at
          allowed_end = at + meter.readable(Math.min(finish - at, CHUNK_BYTES), at)
        end
        bound = Math.min(finish, allowed_end)
        if @ascii_loops.unsafe_fetch(row // @class_count) != 0
          at = Core::ByteScan.skip_ascii(bytes, at, bound)
          next if at >= bound
        end
        while at < bound
          step = steps[row &+ classes[bytes.unsafe_fetch(at)]]
          break unless step >= 0 && step & 1 == 0
          at &+= 1
          if step >> 2 == row
            while at < bound && steps[row &+ classes[bytes.unsafe_fetch(at)]] == step
              at &+= 1
            end
          end
          row = step >> 2
        end
        next if at >= bound
        cell = row &+ classes[bytes.unsafe_fetch(at)]
        step = steps[cell]
        return false if step < 0
        return false unless take(@cells.unsafe_fetch(cell), bytes, at, search_start, slots)
        row = step >> 2
        at &+= 1
      end
      meter.charge(finish - charged + 1, charged)
      index = @match_edges.unsafe_fetch(row // @class_count)
      return false if index < 0
      take(index, bytes, finish, search_start, slots)
    end

    private def take(edge : Int32, bytes : Bytes, at : Int32, search_start : Int32, slots : Pointer(Int32)) : Bool
      looks = @edge_looks.unsafe_fetch(edge)
      while looks != 0
        kind = Program::LookKind.new(looks.trailing_zeros_count.to_i32)
        return false unless Look.holds?(kind, bytes, at, search_start)
        looks &= looks - 1
      end
      saved = @edge_slots.unsafe_fetch(edge)
      while saved != 0
        slots[saved.trailing_zeros_count] = at
        saved &= saved - 1
      end
      true
    end
  end

  # A pattern compiled while the application built (see
  # `Mica::Regex.static`). `F` and `R` are the integer types of the forward
  # and reverse DFA tables, `N` that of the capture pass's NFA, and
  # `SCRATCH` the 32-bit words of stack the capture pass takes.
  #
  # **Search.** The forward DFA finds the end of the leftmost-first match,
  # the reverse DFA its start (exactly as the runtime engine's lazy DFAs
  # do, but with every state built in advance), and when groups are asked
  # for, a Pike VM runs over the match span alone. Nothing is allocated:
  # the tables are read-only data, and the meter and the Pike VM's scratch
  # live in the caller's stack frame.
  #
  # **Limits.** The work budget is `SearchLimits#work_budget` for the
  # program's state count, as on the runtime engine; every chunk of bytes
  # is allowed by the meter before it is read, and the deadline is read
  # when the call starts and at each clock checkpoint.
  struct StaticPattern(F, R, N, SCRATCH)
    # The forward and reverse search results besides a position.
    NO_MATCH = -1
    # The most bytes read between charges.
    CHUNK_BYTES = 4096

    getter source : String
    getter options : CompileOptions
    @classes : Slice(UInt8)
    @forward : StaticDirection(F)
    @reverse : StaticDirection(R)
    @program : StaticProgram(N)
    @one_pass : StaticOnePass
    @unicode_words : Bool
    @final_lf : Bool
    @anchored_start : Bool
    @budget_states : Int32
    @slot_count : Int32
    @word_offset : Int32
    @edge_symbol : Int32

    def initialize(*, @source : String, @options : CompileOptions, @classes : Slice(UInt8),
                   @forward : StaticDirection(F), @reverse : StaticDirection(R), @program : StaticProgram(N),
                   @one_pass : StaticOnePass, @unicode_words : Bool, @final_lf : Bool, @anchored_start : Bool, @budget_states : Int32,
                   @slot_count : Int32)
      class_count = @classes.max.to_i32 + 1
      @edge_symbol = class_count
      @word_offset = class_count + 2
    end

    # The number of capturing groups (group 0 not included).
    def capture_count : Int32
      @slot_count // 2 - 1
    end

    # True when the static path holds this pattern (a `StaticFallback`
    # says false).
    def static? : Bool
      true
    end

    # Returns true when *haystack* has a match at or after *byte_offset*;
    # stops at the first match end it reaches.
    def matches?(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                 deadline : Time::Span? = nil) : Bool
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate: true)
      bytes = haystack.to_slice
      return false unless start_allowed?(bytes, byte_offset)
      find_end(bytes, byte_offset, @anchored_start, true, meter) >= 0
    end

    # Returns the span of the leftmost-first match at or after
    # *byte_offset*, or nil. Raises `ArgumentError` when *byte_offset* is
    # negative or inside a character, `Mica::EncodingError` when
    # *haystack* is not valid UTF-8.
    def search(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
               deadline : Time::Span? = nil) : StaticSpan?
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate: true)
      find_span(haystack.to_slice, byte_offset, meter)
    end

    # :nodoc:
    # As `search`, for a *haystack* the caller already validated (an
    # iteration over one string, or the benchmark adapter after its first
    # search).
    def search_validated(haystack : String, byte_offset : Int32, limits : SearchLimits,
                         deadline : Time::Span?) : StaticSpan?
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate: false)
      find_span(haystack.to_slice, byte_offset, meter)
    end

    # Finds the leftmost-first match at or after *byte_offset* with its
    # groups and yields them (see `StaticGroups`); returns the block's value,
    # or nil when nothing matches.
    def search_groups(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                      deadline : Time::Span? = nil, validated : Bool = false, & : StaticGroups -> _)
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate: !validated)
      bytes = haystack.to_slice
      span = find_span(bytes, byte_offset, meter)
      return nil unless span
      scratch = uninitialized StaticArray(Int32, SCRATCH)
      output = Slice.new(scratch.to_unsafe, @slot_count)
      if @slot_count > 2
        read_by_one_pass = @one_pass.present? &&
                           @one_pass.captures(bytes, span.byte_begin, span.byte_end, byte_offset, @classes.to_unsafe,
                             output.to_unsafe, @slot_count, meter)
        unless read_by_one_pass
          capture_pass(bytes, span.byte_begin, span.byte_end, byte_offset, meter, scratch.to_unsafe + @slot_count)
        end
      else
        output[0] = span.byte_begin
        output[1] = span.byte_end
      end
      yield StaticGroups.new(haystack, output)
    end

    # Yields each leftmost-first match of *haystack* in turn, stepping over
    # one character after an empty match as `String#scan` does. The work
    # budget covers the whole call.
    def each_match(haystack : String, *, limits : SearchLimits = SearchLimits::REQUEST,
                   deadline : Time::Span? = nil, & : StaticSpan ->) : Nil
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate: true)
      bytes = haystack.to_slice
      byte_offset = 0
      while byte_offset <= bytes.size
        span = find_span(bytes, byte_offset, meter)
        break unless span
        yield span
        meter.enforce_deadline(span.byte_end)
        byte_offset = if span.byte_end > span.byte_begin
                        span.byte_end
                      elsif span.byte_end >= bytes.size
                        bytes.size + 1
                      else
                        span.byte_end + Core::UTF8.sequence_length(bytes.unsafe_fetch(span.byte_end))
                      end
      end
    end

    private def open(counters : Pointer(Int64), haystack : String, limits : SearchLimits, deadline : Time::Span?,
                     validate : Bool) : StaticMeter
      meter = StaticMeter.new(counters, limits, @budget_states, haystack.bytesize, deadline)
      # The deadline is read before the haystack is, as on the runtime
      # engine.
      meter.enforce_deadline(0)
      if validate
        bytes = haystack.to_slice
        meter.charge(bytes.size, 0)
        if offset = Core::UTF8.first_invalid_offset(bytes)
          raise Mica::EncodingError.new("The haystack is not valid UTF-8", Core::Position.new(offset.to_i64))
        end
      end
      meter
    end

    private def start_allowed?(bytes : Bytes, byte_offset : Int32) : Bool
      raise ArgumentError.new("Negative byte index: #{byte_offset}") if byte_offset < 0
      return false if byte_offset > bytes.size
      if byte_offset < bytes.size && bytes.unsafe_fetch(byte_offset) & 0xC0 == 0x80
        raise ArgumentError.new("Byte index #{byte_offset} is inside a UTF-8 character")
      end
      true
    end

    private def find_span(bytes : Bytes, byte_offset : Int32, meter : StaticMeter) : StaticSpan?
      return nil unless start_allowed?(bytes, byte_offset)
      anchored = @anchored_start
      finish = find_end(bytes, byte_offset, anchored, false, meter)
      return nil if finish < 0
      start = anchored ? byte_offset : find_start(bytes, finish, byte_offset, meter)
      raise Mica::Error.new("internal error: the reverse DFA found no start for #{finish}") if start < 0
      StaticSpan.new(start, finish)
    end

    # Searches forward from *start* for the end of the leftmost-first
    # match (`LazyDFA#find_end` over a complete table).
    private def find_end(bytes : Bytes, start : Int32, anchored : Bool, earliest : Bool, meter : StaticMeter) : Int32
      size = bytes.size
      limit = @final_lf && size > start && bytes.unsafe_fetch(size - 1) == Look::LINE_FEED ? size - 1 : size
      direction = @forward
      stride = direction.stride
      table = direction.table.to_unsafe
      classes = @classes.to_unsafe
      special_limit = direction.special_limit
      accel_limit = direction.accel_limit
      dead_limit = 2 * stride
      words = @unicode_words
      word_offset = @word_offset
      flags = anchored ? LazyDFA::START_PENDING : LazyDFA::UNANCHORED
      flags |= start == 0 ? LazyDFA::TEXT_EDGE : symbol_flags(bytes, start - 1)
      current = direction.starts.unsafe_fetch(direction.start_index(flags) * 2 + (anchored ? 1 : 0)).to_i32
      last_end = NO_MATCH
      at = start
      wide_start = wide_end = 0
      wide_word = false
      while at < limit
        chunk_end = at + meter.readable(Math.min(limit - at, CHUNK_BYTES), at)
        chunk_start = at
        while at < chunk_end
          byte = bytes.unsafe_fetch(at)
          symbol = classes[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(bytes, at) unless wide_start <= at < wide_end
            symbol &+= word_offset if wide_word
          end
          current = table[current &+ symbol].to_i32
          at &+= 1
          next if current >= accel_limit
          if current >= special_limit
            accel = direction.accel_bytes.unsafe_fetch((current - special_limit) // stride)
            at = StaticByteScan.forward(bytes, at, chunk_end, accel)
            next
          end
          if current < dead_limit
            last_end = at - 1 if current == stride
            meter.charge(at - chunk_start, at)
            return last_end
          end
          last_end = at - 1
          if earliest
            meter.charge(at - chunk_start, at)
            return last_end
          end
        end
        meter.charge(at - chunk_start, at)
      end
      if at == size - 1 && limit == size - 1
        meter.charge(1, at)
        current = table[current &+ @edge_symbol &+ 1].to_i32
        at += 1
        if current < special_limit
          if current >= dead_limit || current == stride
            last_end = at - 1
            return last_end if earliest
          end
          return last_end if current < dead_limit
        end
      end
      current = table[current &+ @edge_symbol].to_i32
      last_end = size if current < special_limit && (current >= dead_limit || current == stride)
      last_end
    end

    # Searches backward from *finish* to no lower than *lower_bound* for
    # the leftmost start of a match ending at *finish*
    # (`LazyDFA#find_start` over a complete table).
    private def find_start(bytes : Bytes, finish : Int32, lower_bound : Int32, meter : StaticMeter) : Int32
      size = bytes.size
      direction = @reverse
      stride = direction.stride
      table = direction.table.to_unsafe
      classes = @classes.to_unsafe
      special_limit = direction.special_limit
      accel_limit = direction.accel_limit
      dead_limit = 2 * stride
      words = @unicode_words
      word_offset = @word_offset
      flags = 0
      if finish == size
        flags = LazyDFA::TEXT_EDGE
      else
        byte = bytes.unsafe_fetch(finish)
        flags = symbol_flags(bytes, finish)
        flags |= LazyDFA::PREVIOUS_TAIL if byte & 0xC0 == 0x80
        flags |= LazyDFA::FINAL_LF_EDGE if finish == size - 1 && byte == Look::LINE_FEED
      end
      current = direction.starts.unsafe_fetch(direction.start_index(flags)).to_i32
      last_start = NO_MATCH
      at = finish
      wide_start = wide_end = 0
      wide_word = false
      while at > lower_bound
        chunk_end = at - meter.readable(Math.min(at - lower_bound, CHUNK_BYTES), at)
        chunk_start = at
        while at > chunk_end
          byte = bytes.unsafe_fetch(at - 1)
          symbol = classes[byte].to_i32
          if words && byte >= 0x80
            wide_start, wide_end, wide_word = LazyDFA.wide_char(bytes, at - 1) unless wide_start <= at - 1 < wide_end
            symbol &+= word_offset if wide_word
          end
          current = table[current &+ symbol].to_i32
          at &-= 1
          next if current >= accel_limit
          if current >= special_limit
            accel = direction.accel_bytes.unsafe_fetch((current - special_limit) // stride)
            at = StaticByteScan.backward(bytes, at, chunk_end, accel)
            next
          end
          last_start = at + 1 if current >= dead_limit || current == stride
          if current < dead_limit
            meter.charge(chunk_start - at, at)
            return last_start
          end
        end
        meter.charge(chunk_start - at, at)
      end
      symbol = lower_bound > 0 ? symbol_at(bytes, lower_bound - 1) : @edge_symbol
      current = table[current &+ symbol].to_i32
      last_start = lower_bound if current < special_limit && (current >= dead_limit || current == stride)
      last_start
    end

    # The state flags reading byte *at* leaves for the next position (see
    # `LazyDFA`).
    private def symbol_flags(bytes : Bytes, at : Int32) : Int32
      byte = bytes.unsafe_fetch(at)
      flags = 0
      flags |= LazyDFA::PREVIOUS_LF if byte == Look::LINE_FEED
      if byte < 0x80
        flags |= LazyDFA::PREVIOUS_WORD | LazyDFA::PREVIOUS_UNICODE_WORD if Look.word_code_point?(byte.to_i32, true)
      else
        flags |= LazyDFA::PREVIOUS_WIDE
        flags |= LazyDFA::PREVIOUS_UNICODE_WORD if @unicode_words && LazyDFA.wide_char(bytes, at)[2]
      end
      flags
    end

    private def symbol_at(bytes : Bytes, at : Int32) : Int32
      byte = bytes.unsafe_fetch(at)
      symbol = @classes.unsafe_fetch(byte).to_i32
      symbol += @word_offset if @unicode_words && byte >= 0x80 && LazyDFA.wide_char(bytes, at)[2]
      symbol
    end

    # Runs the Pike VM anchored at *start* over the span alone (bytes below
    # *finish*), as the runtime engine's capture pass does, and writes the
    # groups to the first `slot_count` words before *scratch*. The rest of
    # the scratch space: two slot tables (states × slots), two sparse sets
    # (dense and sparse, states each), the closure stack (two words per
    # frame) and one slot vector.
    private def capture_pass(bytes : Bytes, start : Int32, finish : Int32, search_start : Int32, meter : StaticMeter,
                             scratch : Pointer(Int32)) : Nil
      output = scratch - @slot_count
      program = @program
      states = program.size
      slots = @slot_count
      current_slots = scratch
      next_slots = scratch + states * slots
      sets = scratch + 2 * states * slots
      current_dense = sets
      current_sparse = sets + states
      next_dense = sets + 2 * states
      next_sparse = sets + 3 * states
      stack = sets + 4 * states
      thread_slots = stack + 2 * states
      current_size = 0
      next_size = 0
      matched = false
      at = start
      while true
        break if current_size == 0 && (matched || at > start)
        if !matched && at == start
          slots.times { |index| thread_slots[index] = -1 }
          current_size = closure(program.start_state, at, bytes, search_start, meter, current_dense, current_sparse,
            current_slots, current_size, stack, thread_slots)
        end
        index = 0
        while index < current_size
          state = current_dense[index]
          index += 1
          meter.charge(1, at)
          kind = Program::StateKind.new(program.kinds.unsafe_fetch(state))
          target = -1
          case kind
          when .match?
            (current_slots + state * slots).copy_to(output, slots)
            matched = true
            break
          when .byte_range?
            next if at >= finish
            byte = bytes.unsafe_fetch(at)
            next unless program.lows.unsafe_fetch(state) <= byte <= program.highs.unsafe_fetch(state)
            target = program.next_states.unsafe_fetch(state).to_i32
          when .sparse?
            next if at >= finish
            target = program.sparse_target(state, bytes.unsafe_fetch(at))
          end
          next if target < 0
          meter.charge(slots, at)
          thread_slots.copy_from(current_slots + state * slots, slots)
          next_size = closure(target, at + 1, bytes, search_start, meter, next_dense, next_sparse, next_slots,
            next_size, stack, thread_slots)
        end
        break if at >= finish
        current_slots, next_slots = next_slots, current_slots
        current_dense, next_dense = next_dense, current_dense
        current_sparse, next_sparse = next_sparse, current_sparse
        current_size = next_size
        next_size = 0
        at += 1
      end
      unless matched && output[0] == start && output[1] == finish
        raise Mica::Error.new("internal error: the static capture pass did not find the span #{start}...#{finish}")
      end
    end

    # Adds the threads reachable from *state_index* at *at* to a list (its
    # dense and sparse sets and slot table) in priority order, as
    # `PikeVM#closure` does, and returns the list's new size.
    private def closure(state_index : Int32, at : Int32, bytes : Bytes, search_start : Int32, meter : StaticMeter,
                        dense : Pointer(Int32), sparse : Pointer(Int32), table : Pointer(Int32), size : Int32,
                        stack : Pointer(Int32), thread_slots : Pointer(Int32)) : Int32
      program = @program
      slots = @slot_count
      depth = 1
      stack[0] = state_index
      stack[1] = 0
      while depth > 0
        depth -= 1
        frame = stack[depth * 2]
        if frame < 0
          thread_slots[-(frame + 1)] = stack[depth * 2 + 1]
          next
        end
        current = frame
        while true
          member = sparse[current]
          break if 0 <= member < size && dense[member] == current
          sparse[current] = size
          dense[size] = current
          size += 1
          meter.charge(1, at)
          kind = Program::StateKind.new(program.kinds.unsafe_fetch(current))
          case kind
          when .byte_range?, .sparse?, .match?
            meter.charge(slots, at)
            (table + current * slots).copy_from(thread_slots, slots)
            break
          when .split?
            stack[depth * 2] = program.alternates.unsafe_fetch(current).to_i32
            depth += 1
            current = program.next_states.unsafe_fetch(current).to_i32
          when .save?
            slot = program.arguments.unsafe_fetch(current).to_i32
            if slot < slots
              stack[depth * 2] = -(slot + 1)
              stack[depth * 2 + 1] = thread_slots[slot]
              depth += 1
              thread_slots[slot] = at
            end
            current = program.next_states.unsafe_fetch(current).to_i32
          when .look?
            kind = Program::LookKind.new(program.arguments.unsafe_fetch(current).to_i32)
            break unless Look.holds?(kind, bytes, at, search_start)
            current = program.next_states.unsafe_fetch(current).to_i32
          else
            break
          end
        end
      end
      size
    end
  end

  # A static pattern the static path could not hold (see
  # `Mica::Regex.static`): it compiles on the runtime engine when the
  # application starts, under `CompileLimits::TRUSTED_PATTERN`, and offers
  # the same methods as `StaticPattern`, which allocate as the runtime
  # engine does.
  class StaticFallback
    getter source : String
    getter options : CompileOptions
    # Why the static path refused the pattern.
    getter reason : String
    getter expression : Expression

    def initialize(@source : String, @options : CompileOptions, @reason : String)
      @expression = Regex.compile(@source, dialect: :crystal, compile_limits: CompileLimits::TRUSTED_PATTERN,
        options: @options)
    end

    def capture_count : Int32
      @expression.capture_count
    end

    def static? : Bool
      false
    end

    def matches?(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                 deadline : Time::Span? = nil) : Bool
      @expression.matches_at_byte_index?(haystack, byte_offset, limits: limits, timeout: deadline)
    end

    def search(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
               deadline : Time::Span? = nil) : StaticSpan?
      match = @expression.search(haystack, byte_offset, limits: limits, deadline: deadline)
      match ? StaticSpan.new(match.byte_begin(0), match.byte_end(0)) : nil
    end

    # :nodoc:
    def search_validated(haystack : String, byte_offset : Int32, limits : SearchLimits,
                         deadline : Time::Span?) : StaticSpan?
      search(haystack, byte_offset, limits: limits, deadline: deadline)
    end

    def search_groups(haystack : String, byte_offset : Int32 = 0, *, limits : SearchLimits = SearchLimits::REQUEST,
                      deadline : Time::Span? = nil, validated : Bool = false, & : StaticGroups -> _)
      match = @expression.search(haystack, byte_offset, limits: limits, deadline: deadline)
      return nil unless match
      slots = Slice(Int32).new(match.size * 2) do |index|
        group = index // 2
        found = match[group]?
        next -1 unless found
        index.even? ? match.byte_begin(group) : match.byte_end(group)
      end
      yield StaticGroups.new(haystack, slots)
    end

    def each_match(haystack : String, *, limits : SearchLimits = SearchLimits::REQUEST,
                   deadline : Time::Span? = nil, & : StaticSpan ->) : Nil
      @expression.each_match(haystack, limits: limits, timeout: deadline) do |match|
        yield StaticSpan.new(match.byte_begin(0), match.byte_end(0))
      end
    end
  end
end
