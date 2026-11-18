module Mica::Regex
  # A program's NFA with every edge turned around, for the reverse lazy DFA
  # (roadmap 6.2.1): it starts at the program's match state, reads the
  # haystack backward from a match end, and accepts on reaching the
  # program's start state. Priority plays no part in reverse (the reverse
  # search wants every start, and keeps the leftmost), so it is a plain NFA.
  #
  # Each forward state keeps its number. Edges are stored compressed: for
  # node v, the epsilon edges into v's forward predecessors (with the
  # assertion that guarded the forward edge, or -1) and the byte edges, a
  # forward byte transition u -> v becoming v -> u on the same bytes.
  class ReverseNFA
    getter start_node : Int32
    getter accept_node : Int32
    @epsilon_offsets : Array(Int32)
    @epsilon_targets : Array(Int32)
    @epsilon_looks : Array(Int32)
    @byte_offsets : Array(Int32)
    @list_of_byte_edges : Array(Program::Transition)

    def initialize(program : Program)
      states = program.list_of_states
      count = states.size
      @accept_node = program.start_state
      @start_node = states.index(&.kind.match?) || raise Mica::Error.new("internal error: the program has no match state")
      epsilon_counts = Array(Int32).new(count + 1, 0)
      byte_counts = Array(Int32).new(count + 1, 0)
      each_forward_edge(program) do |source, target, look, low, high|
        if look == BYTE_EDGE
          byte_counts[target + 1] += 1
        else
          epsilon_counts[target + 1] += 1
        end
      end
      count.times do |index|
        epsilon_counts[index + 1] += epsilon_counts[index]
        byte_counts[index + 1] += byte_counts[index]
      end
      @epsilon_offsets = epsilon_counts.dup
      @byte_offsets = byte_counts.dup
      @epsilon_targets = Array(Int32).new(epsilon_counts[count], 0)
      @epsilon_looks = Array(Int32).new(epsilon_counts[count], 0)
      @list_of_byte_edges = Array(Program::Transition).new(byte_counts[count], Program::Transition.new(0_u8, 0_u8, 0))
      each_forward_edge(program) do |source, target, look, low, high|
        if look == BYTE_EDGE
          @list_of_byte_edges[byte_counts[target]] = Program::Transition.new(low, high, source)
          byte_counts[target] += 1
        else
          @epsilon_targets[epsilon_counts[target]] = source
          @epsilon_looks[epsilon_counts[target]] = look
          epsilon_counts[target] += 1
        end
      end
    end

    # The number of nodes.
    def node_count : Int32
      @epsilon_offsets.size - 1
    end

    # Yields each epsilon edge out of *node*: the target and its assertion
    # (a `Program::LookKind` value, or -1).
    @[AlwaysInline]
    def each_epsilon(node : Int32, & : Int32, Int32 ->) : Nil
      (@epsilon_offsets.unsafe_fetch(node)...@epsilon_offsets.unsafe_fetch(node + 1)).each do |index|
        yield @epsilon_targets.unsafe_fetch(index), @epsilon_looks.unsafe_fetch(index)
      end
    end

    # True when *node* has byte edges.
    def consumes?(node : Int32) : Bool
      @byte_offsets.unsafe_fetch(node) < @byte_offsets.unsafe_fetch(node + 1)
    end

    # Yields the target of each byte edge out of *node* that holds *byte*.
    @[AlwaysInline]
    def each_byte_target(node : Int32, byte : UInt8, & : Int32 ->) : Nil
      (@byte_offsets.unsafe_fetch(node)...@byte_offsets.unsafe_fetch(node + 1)).each do |index|
        edge = @list_of_byte_edges.unsafe_fetch(index)
        yield edge.target if edge.low <= byte <= edge.high
      end
    end

    private BYTE_EDGE = -2

    private def each_forward_edge(program : Program, & : Int32, Int32, Int32, UInt8, UInt8 ->) : Nil
      program.list_of_states.each_with_index do |state, source|
        case state.kind
        when .byte_range?
          yield source, state.next_state, BYTE_EDGE, state.low, state.high
        when .sparse?
          state.alternate.times do |offset|
            transition = program.list_of_transitions[state.argument + offset]
            yield source, transition.target, BYTE_EDGE, transition.low, transition.high
          end
        when .split?
          yield source, state.next_state, -1, 0_u8, 0_u8
          yield source, state.alternate, -1, 0_u8, 0_u8
        when .save?
          yield source, state.next_state, -1, 0_u8, 0_u8
        when .look?
          yield source, state.next_state, state.argument, 0_u8, 0_u8
        end
      end
    end
  end
end
