module Mica::Regex
  # What a match of a `Program` needs before any engine runs: the fewest
  # bytes it can span, and the bytes it can start with. `Expression` reads
  # it to answer a search over a short haystack that cannot match without
  # taking a lease or starting an engine (see "Short searches" in
  # docs/regex.md).
  #
  # Both are read from the NFA, with every assertion taken as passing, so
  # they over-approximate the matches: a haystack the filter rejects has no
  # match, and one it accepts may or may not.
  #
  # ```
  # filter = Mica::Regex::Expression.new("\\d+px", compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
  #   .program.plan.start_filter
  # filter.minimum_bytes                        # => 3
  # filter.rejects?("12p".to_slice, 0, false)   # => false
  # filter.rejects?("ab px".to_slice, 0, false) # => true
  # ```
  class StartFilter
    # The fewest bytes a match spans (0 when it can be empty).
    getter minimum_bytes : Int32
    # One bit per byte value that can start a non-empty match.
    @start_bytes = StaticArray(UInt64, 4).new(0_u64)

    def initialize(program : Program)
      @minimum_bytes = StartFilter.shortest_match(program)
      collect_start_bytes(program) if @minimum_bytes > 0
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
      (from..last).none? { |index| starts?(haystack.unsafe_fetch(index)) }
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
