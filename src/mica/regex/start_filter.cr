module Mica::Regex
  # What a match of a `Program` needs before any engine runs: the fewest
  # bytes it can span, and the bytes it can start with. `Expression` reads
  # it to answer a search over a short haystack that cannot match without
  # taking a lease or starting an engine (see "Short searches" in
  # docs/regex.md).
  #
  # It also holds up to `MAX_REQUIRED_BYTES` ASCII bytes every match
  # contains (`:` in `.*:(\d+)`, `y` and `x` in `(x+x+)+y`).
  #
  # All are read from the NFA, with every assertion taken as passing, so
  # they over-approximate the matches: a haystack the filter rejects has no
  # match, and one it accepts may or may not.
  #
  # ```
  # filter = Mica::Regex::Expression.new("\\d+px", compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  #   .program.plan.start_filter
  # filter.minimum_bytes                        # => 3
  # filter.rejects?("12px".to_slice, 0, false)  # => false
  # filter.rejects?("ab px".to_slice, 0, false) # => true
  # ```
  class StartFilter
    # The fewest bytes a match spans (0 when it can be empty).
    getter minimum_bytes : Int32
    # ASCII bytes every match contains, rarest first (at most
    # `MAX_REQUIRED_BYTES`).
    getter list_of_required_bytes = [] of UInt8
    # One bit per byte value that can start a non-empty match.
    @start_bytes = StaticArray(UInt64, 4).new(0_u64)

    # The most single-byte states `required_byte` considers.
    private MAX_REQUIRED_CANDIDATES = 8
    # The most required bytes kept.
    MAX_REQUIRED_BYTES = 3

    # The one byte every match starts with, or -1.
    @single_start = -1

    def initialize(program : Program)
      @minimum_bytes = StartFilter.shortest_match(program)
      return unless @minimum_bytes > 0
      collect_start_bytes(program)
      @list_of_required_bytes = program.list_of_required_bytes
      list_of_start_bytes = (0..255).select { |byte| starts?(byte.to_u8) }
      @single_start = list_of_start_bytes.first if list_of_start_bytes.size == 1
    end

    # True when no match can start in *haystack* at *from* (or, unless
    # *anchored*, after it): fewer than `minimum_bytes` bytes remain, or no
    # byte where a match could start is one a match starts with. Reads at
    # most the bytes from *from* on.
    def rejects?(haystack : Bytes, from : Int32, anchored : Bool) : Bool
      last = haystack.size - @minimum_bytes
      return true if from > last
      return false if @minimum_bytes == 0
      last = from if anchored
      return true if next_start(haystack, from, last) < 0
      tail = haystack[from..]
      @list_of_required_bytes.any? { |byte| !tail.index(byte) }
    end

    # The most bytes `rejects?` reads from *from* in a haystack of
    # *haystack_size* bytes: the start scan, then one scan per required
    # byte. A caller with a work allowance checks it before the scans run.
    def scan_work(haystack_size : Int32, from : Int32) : Int32
      remaining = Math.max(haystack_size - from, 0)
      remaining * (1 + @list_of_required_bytes.size)
    end

    # The first position from *from* through *last* where a match may
    # start (the byte there is one a match starts with, and at least
    # `minimum_bytes` bytes remain), or -1. Uses `memchr` when matches
    # start with one byte.
    def next_start(haystack : Bytes, from : Int32, last : Int32 = Int32::MAX) : Int32
      last = Math.min(last, haystack.size - @minimum_bytes)
      return -1 if from > last
      return from if @minimum_bytes == 0
      if @single_start >= 0
        found = haystack[from, last + 1 - from].index(@single_start.to_u8)
        return found ? from + found : -1
      end
      (from..last).each { |index| return index if starts?(haystack.unsafe_fetch(index)) }
      -1
    end

    # The rarest ASCII bytes (by `Prefilter.rank`, at most
    # `MAX_REQUIRED_BYTES`) that every path from the start state to the
    # match state reads in a state (or a sparse transition) that reads
    # only that byte. The `MAX_REQUIRED_CANDIDATES` rarest such bytes are
    # tried together: one pass marks, for each state, the candidates some
    # path from the start avoids on the way there, and a candidate the
    # match state cannot be reached without is required. A state is queued
    # again only when it gains a mark, so the pass is O(m) (each state and
    # transition read at most once per candidate, and in practice about
    # once).
    def self.required_bytes(program : Program) : Array(UInt8)
      states = program.list_of_states
      seen = StaticArray(Bool, 128).new(false)
      list_of_candidates = [] of UInt8
      states.each do |state|
        next unless state.kind.byte_range? && state.low == state.high && state.low < 0x80
        next if seen[state.low]
        seen[state.low] = true
        list_of_candidates << state.low
      end
      list_of_required = [] of UInt8
      return list_of_required if list_of_candidates.empty?
      list_of_candidates.sort_by! { |byte| Prefilter.rank(byte) }
      list_of_candidates = list_of_candidates.first(MAX_REQUIRED_CANDIDATES)
      avoided = avoided_on_the_way_to_a_match(program, list_of_candidates)
      list_of_candidates.each_with_index do |byte, index|
        next if avoided.bit(index) == 1
        list_of_required << byte
        break if list_of_required.size == MAX_REQUIRED_BYTES
      end
      list_of_required
    end

    # The candidates (bit i for `list_of_candidates[i]`) that some path from
    # the start state to a match state avoids: no state on it reads only
    # that byte.
    private def self.avoided_on_the_way_to_a_match(program : Program, list_of_candidates : Array(UInt8)) : UInt8
      states = program.list_of_states
      blocking = StaticArray(UInt8, 128).new(0_u8)
      list_of_candidates.each_with_index { |byte, index| blocking[byte] = 1_u8 << index }
      marks = Array(UInt8).new(states.size, 0_u8)
      list_of_pending = [program.start_state]
      marks[program.start_state] = ((1 << list_of_candidates.size) - 1).to_u8
      at_match = 0_u8
      while index = list_of_pending.pop?
        here = marks[index]
        state = states[index]
        case state.kind
        when .match?
          at_match |= here
        when .split?
          mark(marks, list_of_pending, state.next_state, here)
          mark(marks, list_of_pending, state.alternate, here)
        when .save?, .look?
          mark(marks, list_of_pending, state.next_state, here)
        when .byte_range?
          mark(marks, list_of_pending, state.next_state, here & ~blocked_by(blocking, state.low, state.high))
        when .sparse?
          state.alternate.times do |offset|
            transition = program.list_of_transitions[state.argument + offset]
            mark(marks, list_of_pending, transition.target, here & ~blocked_by(blocking, transition.low, transition.high))
          end
        end
      end
      at_match
    end

    # The candidate bits a step reading *low*..*high* blocks: the
    # candidate's own bit when it reads that one byte only.
    @[AlwaysInline]
    private def self.blocked_by(blocking : StaticArray(UInt8, 128), low : UInt8, high : UInt8) : UInt8
      low == high && low < 0x80 ? blocking[low] : 0_u8
    end

    # Adds *bits* to *target*'s marks, queuing it when it gained one.
    @[AlwaysInline]
    private def self.mark(marks : Array(UInt8), list_of_pending : Array(Int32), target : Int32, bits : UInt8) : Nil
      merged = marks.unsafe_fetch(target) | bits
      return if merged == marks.unsafe_fetch(target)
      marks.unsafe_put(target, merged)
      list_of_pending << target
    end

    private def starts?(byte : UInt8) : Bool
      @start_bytes.unsafe_fetch(byte >> 6) & (1_u64 << (byte & 63)) != 0
    end

    # The fewest bytes on any path from the start state to the match state:
    # a 0-1 breadth-first search, byte states weighing one and every other
    # state nothing. O(m) for m states (and their sparse transitions).
    def self.shortest_match(program : Program) : Int32
      states = program.list_of_states
      distance = Array(Int32).new(states.size, Int32::MAX)
      deque = Deque(Int32).new
      distance[program.start_state] = 0
      deque << program.start_state
      while index = deque.shift?
        here = distance[index]
        state = states[index]
        case state.kind
        when .match?
          return here
        when .split?
          relax(distance, deque, state.next_state, here, false)
          relax(distance, deque, state.alternate, here, false)
        when .save?, .look?
          relax(distance, deque, state.next_state, here, false)
        when .byte_range?
          relax(distance, deque, state.next_state, here + 1, true)
        when .sparse?
          state.alternate.times do |offset|
            relax(distance, deque, program.list_of_transitions[state.argument + offset].target, here + 1, true)
          end
        end
      end
      Int32::MAX
    end

    # Lowers *target*'s distance to *candidate* when that is shorter, at the
    # front of *deque* for a free step and at the back for a byte.
    private def self.relax(distance : Array(Int32), deque : Deque(Int32), target : Int32, candidate : Int32,
                           byte : Bool) : Nil
      return unless candidate < distance[target]
      distance[target] = candidate
      byte ? deque.push(target) : deque.unshift(target)
    end

    # Marks every byte a transition reachable from the start state without
    # reading a byte can read first.
    private def collect_start_bytes(program : Program) : Nil
      states = program.list_of_states
      visited = Set(Int32).new
      list_of_pending = [program.start_state]
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = states[index]
        case state.kind
        when .split?
          list_of_pending << state.next_state << state.alternate
        when .save?, .look?
          list_of_pending << state.next_state
        when .byte_range?
          mark(state.low, state.high)
        when .sparse?
          state.alternate.times do |offset|
            transition = program.list_of_transitions[state.argument + offset]
            mark(transition.low, transition.high)
          end
        end
      end
    end

    private def mark(low : UInt8, high : UInt8) : Nil
      (low..high).each { |byte| @start_bytes[byte >> 6] |= 1_u64 << (byte & 63) }
    end
  end
end
