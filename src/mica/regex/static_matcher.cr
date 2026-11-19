module Mica::Regex
  # :nodoc:
  # The layout of a static capture pass's stack scratch (see
  # `StaticMatcher#capture_pass`), shared by the build-time table writer
  # and the matcher.
  module StaticScratch
    # The 32-bit words of scratch for *state_count* NFA states and
    # *slot_count* slots: the groups found, two slot tables, two sparse
    # sets, the closure stack and one slot vector.
    def self.words_for(state_count : Int32, slot_count : Int32) : Int32
      2 * state_count * slot_count + 6 * state_count + 2 * slot_count
    end
  end

  # :nodoc:
  # The search code and tables of a pattern compiled while the application
  # built (see `Mica::Regex.static`). `F` and `R` are the state-id types of
  # the forward and reverse DFA tables and `N` that of the capture pass's
  # NFA (each `UInt8` or `UInt16`). The code is shared by every static
  # pattern with the same three widths: the per-pattern parts (the size of
  # the capture pass's stack scratch) live in `StaticPattern`.
  #
  # **Search.** The forward DFA finds the end of the leftmost-first match,
  # the reverse DFA its start (exactly as the runtime engine's lazy DFAs
  # do, but with every state built in advance), and when groups are asked
  # for, the one-pass DFA or a Pike VM reads the match span alone. Nothing
  # is allocated: the tables are read-only data in the binary, and the
  # meter and the capture scratch live in the caller's stack frame.
  #
  # **Limits.** The work budget is `SearchLimits#work_budget` for the
  # program's state count, as on the runtime engine; every chunk of bytes
  # is allowed by the meter before it is read, and the deadline is read
  # when the call starts and at each clock checkpoint.
  struct StaticMatcher(F, R, N)
    # The search result that is not a position.
    NO_MATCH = -1
    # The most bytes read between charges.
    CHUNK_BYTES = 4096
    # The dead state's id and the id of the dead state that reports a
    # match; every id below `DEAD_LIMIT` is one of them.
    DEAD       = 0
    DEAD_MATCH = 1
    DEAD_LIMIT = 2

    getter source : String
    getter options : CompileOptions
    getter slot_count : Int32
    @classes : Slice(UInt8)
    @forward : StaticDirection(F)
    @reverse : StaticDirection(R)
    @program : StaticProgram(N)
    @one_pass : StaticOnePass
    @unicode_words : Bool
    @final_lf : Bool
    @anchored_start : Bool
    @budget_states : Int32
    @word_offset : Int32
    @edge_symbol : Int32
    # The words of stack scratch `search_groups` needs.
    getter scratch_words : Int32

    def initialize(*, @source : String, @options : CompileOptions, @classes : Slice(UInt8),
                   @forward : StaticDirection(F), @reverse : StaticDirection(R), @program : StaticProgram(N),
                   @one_pass : StaticOnePass, @unicode_words : Bool, @final_lf : Bool, @anchored_start : Bool,
                   @budget_states : Int32, @slot_count : Int32)
      class_count = @classes.max.to_i32 + 1
      @edge_symbol = class_count
      @word_offset = class_count + 2
      @scratch_words = @slot_count > 2 ? StaticScratch.words_for(@program.size, @slot_count) : @slot_count
    end

    # The number of capturing groups (group 0 not included).
    def capture_count : Int32
      @slot_count // 2 - 1
    end

    # True when *haystack* has a match at or after *byte_offset*; stops at
    # the first match end it reaches.
    def matches?(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                 validate : Bool) : Bool
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate)
      bytes = haystack.to_slice
      return false unless start_allowed?(bytes, byte_offset)
      find_end(bytes, byte_offset, @anchored_start, true, meter) >= 0
    end

    # The span of the leftmost-first match at or after *byte_offset*, or
    # nil.
    def search_span(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                    validate : Bool) : Span?
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate)
      find_span(haystack.to_slice, byte_offset, meter)
    end

    # Finds the leftmost-first match at or after *byte_offset* and writes
    # its groups to the first `slot_count` words of *scratch* (which holds
    # *scratch_words* words, the rest for the capture pass); returns false
    # when nothing matches.
    def search_groups(haystack : String, byte_offset : Int32, limits : SearchLimits, deadline : Time::Span?,
                      validate : Bool, scratch : Pointer(Int32), scratch_words : Int32) : Bool
      if scratch_words < @scratch_words
        raise Mica::Error.new("internal error: #{scratch_words} words of capture scratch for #{@source.inspect}")
      end
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, validate)
      bytes = haystack.to_slice
      span = find_span(bytes, byte_offset, meter)
      return false unless span
      if @slot_count > 2
        read_by_one_pass = @one_pass.present? &&
                           @one_pass.captures(bytes, span.byte_begin, span.byte_end, byte_offset, @classes.to_unsafe,
                             scratch, @slot_count, meter)
        capture_pass(bytes, span.byte_begin, span.byte_end, byte_offset, meter, scratch + @slot_count) unless read_by_one_pass
      else
        scratch[0] = span.byte_begin
        scratch[1] = span.byte_end
      end
      true
    end

    # Yields each leftmost-first match of *haystack* in turn, stepping over
    # one character after an empty match as `String#scan` does. One work
    # budget and one deadline cover the whole call.
    def each_span(haystack : String, limits : SearchLimits, deadline : Time::Span?, & : Span ->) : Nil
      counters = uninitialized StaticArray(Int64, 3)
      meter = open(counters.to_unsafe, haystack, limits, deadline, true)
      bytes = haystack.to_slice
      byte_offset = 0
      while byte_offset <= bytes.size
        span = find_span(bytes, byte_offset, meter)
        break unless span
        yield span
        meter.enforce_deadline(span.byte_end)
        byte_offset = if !span.empty?
                        span.byte_end
                      elsif span.byte_end >= bytes.size
                        bytes.size + 1
                      else
                        span.byte_end + Core::UTF8.sequence_length(bytes.unsafe_fetch(span.byte_end))
                      end
      end
    end

    # Starts a call's meter, reads the deadline and (with *validate*)
    # checks that *haystack* is valid UTF-8, charging a byte per operation.
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

    private def find_span(bytes : Bytes, byte_offset : Int32, meter : StaticMeter) : Span?
      return nil unless start_allowed?(bytes, byte_offset)
      anchored = @anchored_start
      finish = find_end(bytes, byte_offset, anchored, false, meter)
      return nil if finish < 0
      start = anchored ? byte_offset : find_start(bytes, finish, byte_offset, meter)
      raise Mica::Error.new("internal error: the reverse DFA found no start for #{finish}") if start < 0
      Span.new(start, finish)
    end

    # Searches forward from *start* for the end of the leftmost-first
    # match (`LazyDFA#find_end` over a complete table).
    private def find_end(bytes : Bytes, start : Int32, anchored : Bool, earliest : Bool, meter : StaticMeter) : Int32
      size = bytes.size
      limit = @final_lf && size > start && bytes.unsafe_fetch(size - 1) == Look::LINE_FEED ? size - 1 : size
      direction = @forward
      shift = direction.shift
      table = direction.table.to_unsafe
      classes = @classes.to_unsafe
      special_limit = direction.special_limit
      accel_limit = direction.accel_limit
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
          current = table[(current << shift) &+ symbol].to_i32
          at &+= 1
          next if current >= accel_limit
          if current >= special_limit
            at = StaticByteScan.forward(bytes, at, chunk_end, direction.accel_bytes.unsafe_fetch(current - special_limit))
            next
          end
          if current < DEAD_LIMIT
            last_end = at - 1 if current == DEAD_MATCH
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
        current = table[(current << shift) &+ @edge_symbol &+ 1].to_i32
        at += 1
        if current < special_limit
          if current >= DEAD_LIMIT || current == DEAD_MATCH
            last_end = at - 1
            return last_end if earliest
          end
          return last_end if current < DEAD_LIMIT
        end
      end
      current = table[(current << shift) &+ @edge_symbol].to_i32
      last_end = size if current < special_limit && current != DEAD
      last_end
    end

    # Searches backward from *finish* to no lower than *lower_bound* for
    # the leftmost start of a match ending at *finish*
    # (`LazyDFA#find_start` over a complete table).
    private def find_start(bytes : Bytes, finish : Int32, lower_bound : Int32, meter : StaticMeter) : Int32
      size = bytes.size
      direction = @reverse
      shift = direction.shift
      table = direction.table.to_unsafe
      classes = @classes.to_unsafe
      special_limit = direction.special_limit
      accel_limit = direction.accel_limit
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
          current = table[(current << shift) &+ symbol].to_i32
          at &-= 1
          next if current >= accel_limit
          if current >= special_limit
            at = StaticByteScan.backward(bytes, at, chunk_end, direction.accel_bytes.unsafe_fetch(current - special_limit))
            next
          end
          last_start = at + 1 if current != DEAD
          if current < DEAD_LIMIT
            meter.charge(chunk_start - at, at)
            return last_start
          end
        end
        meter.charge(chunk_start - at, at)
      end
      symbol = lower_bound > 0 ? symbol_at(bytes, lower_bound - 1) : @edge_symbol
      current = table[(current << shift) &+ symbol].to_i32
      last_start = lower_bound if current < special_limit && current != DEAD
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
end
