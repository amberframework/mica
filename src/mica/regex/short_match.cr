module Mica::Regex
  # :nodoc:
  # What a program's matches look like when every one is short: the most
  # bytes a match can span, and (when they are few) the bytes a match's
  # last byte can be. `LazyDFA#find_from_each_start` uses both: it runs the
  # DFA anchored at each start, which reads at most `longest` + 1 bytes
  # per start, and it skips every start more than `longest` bytes before
  # the next occurrence of a final byte, as no match can begin there.
  #
  # ```
  # # [a-q][^u-z]{13}x: at most 1 + 13·4 + 1 bytes, always ending in "x".
  # short_match.longest             # => 54
  # short_match.list_of_final_bytes # => [120_u8]
  # ```
  class ShortMatch
    # The longest match that qualifies, in bytes.
    BOUND = 512
    # The most distinct final bytes kept; with more, `list_of_final_bytes`
    # is empty and no start is skipped.
    MAX_FINAL_BYTES = 3

    # The most bytes a match can span.
    getter longest : Int32
    # The bytes every match ends with, or empty when they are more than
    # `MAX_FINAL_BYTES` (or the program can match the empty string).
    getter list_of_final_bytes : Array(UInt8)

    def initialize(@longest : Int32, @list_of_final_bytes : Array(UInt8))
    end

    # Returns the analysis of *program*, or nil when a match can span more
    # than `BOUND` bytes (or any number, through a loop that reads input).
    def self.analyze(program : Program) : ShortMatch?
      longest = longest_match(program)
      return nil unless longest
      new(longest, final_bytes(program))
    end

    # Returns the most bytes a match of *program* can span, or nil when a
    # loop reads input or the length passes `BOUND`. One depth-first pass:
    # a state's longest path to the match state is known once its
    # successors' are, and a successor still on the stack is a loop.
    def self.longest_match(program : Program) : Int32?
      states = program.list_of_states
      transitions = program.list_of_transitions
      # UNSEEN, ON_STACK, or the longest path in bytes.
      longest = Array(Int32).new(states.size, UNSEEN)
      list_of_pending = [program.start_state]
      while index = list_of_pending.last?
        if longest[index] == UNSEEN
          longest[index] = ON_STACK
          return nil unless push_successors(program, states[index], longest, list_of_pending)
          next
        end
        list_of_pending.pop
        next if longest[index] >= 0
        state = states[index]
        result = case state.kind
                 when .byte_range?
                   longest[state.next_state] + 1
                 when .save?, .look?
                   longest[state.next_state]
                 when .split?
                   Math.max(longest[state.next_state], longest[state.alternate])
                 when .sparse?
                   most = 0
                   state.alternate.times do |offset|
                     most = Math.max(most, longest[transitions[state.argument + offset].target] + 1)
                   end
                   most
                 else
                   0
                 end
        return nil if result > BOUND
        longest[index] = result
      end
      longest[program.start_state]
    end

    private UNSEEN   = -2
    private ON_STACK = -1

    # Pushes the successors of *state* whose longest path is not known yet;
    # false when one is on the stack (a loop).
    private def self.push_successors(program : Program, state : Program::State, longest : Array(Int32),
                                     list_of_pending : Array(Int32)) : Bool
      case state.kind
      when .byte_range?, .save?, .look?
        push_successor(state.next_state, longest, list_of_pending)
      when .split?
        push_successor(state.next_state, longest, list_of_pending) &&
          push_successor(state.alternate, longest, list_of_pending)
      when .sparse?
        transitions = program.list_of_transitions
        (0...state.alternate).all? do |offset|
          push_successor(transitions[state.argument + offset].target, longest, list_of_pending)
        end
      else
        true
      end
    end

    private def self.push_successor(successor : Int32, longest : Array(Int32), list_of_pending : Array(Int32)) : Bool
      length = longest[successor]
      return false if length == ON_STACK
      list_of_pending << successor if length == UNSEEN
      true
    end

    # Returns the bytes a match of *program* can end with (the byte read
    # just before the match state is reached through steps that read
    # nothing), or an empty list when they are more than `MAX_FINAL_BYTES`
    # or the start state reaches the match state reading nothing.
    def self.final_bytes(program : Program) : Array(UInt8)
      states = program.list_of_states
      # The states that reach a match state reading nothing, found by
      # walking the steps that read nothing backward from the match states.
      list_of_predecessors = Array(Array(Int32)?).new(states.size, nil)
      states.each_with_index do |state, index|
        case state.kind
        when .split?
          (list_of_predecessors[state.next_state] ||= [] of Int32) << index
          (list_of_predecessors[state.alternate] ||= [] of Int32) << index
        when .save?, .look?
          (list_of_predecessors[state.next_state] ||= [] of Int32) << index
        end
      end
      reaches_match = Array(Bool).new(states.size, false)
      list_of_pending = [] of Int32
      states.each_with_index do |state, index|
        next unless state.kind.match?
        reaches_match[index] = true
        list_of_pending << index
      end
      while index = list_of_pending.pop?
        list_of_predecessors[index].try &.each do |predecessor|
          next if reaches_match[predecessor]
          reaches_match[predecessor] = true
          list_of_pending << predecessor
        end
      end
      none = [] of UInt8
      return none if reaches_match[program.start_state]
      list_of_final_bytes = [] of UInt8
      transitions = program.list_of_transitions
      states.each do |state|
        if state.kind.byte_range?
          next unless reaches_match[state.next_state]
          return none unless add_final_bytes(list_of_final_bytes, state.low, state.high)
        elsif state.kind.sparse?
          state.alternate.times do |offset|
            transition = transitions[state.argument + offset]
            next unless reaches_match[transition.target]
            return none unless add_final_bytes(list_of_final_bytes, transition.low, transition.high)
          end
        end
      end
      list_of_final_bytes
    end

    # Adds *low*..*high* to *list_of_final_bytes*; false when the list
    # would pass `MAX_FINAL_BYTES`.
    private def self.add_final_bytes(list_of_final_bytes : Array(UInt8), low : UInt8, high : UInt8) : Bool
      return false if high.to_i32 - low.to_i32 >= MAX_FINAL_BYTES
      (low..high).each do |byte|
        list_of_final_bytes << byte unless list_of_final_bytes.includes?(byte)
        return false if list_of_final_bytes.size > MAX_FINAL_BYTES
      end
      true
    end
  end
end
