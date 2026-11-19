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
  #
  # **Classes read backward.** A class compiles to a trie of UTF-8
  # sequences that share their leading bytes. Turned around, it would
  # branch at its last byte: a continuation byte read backward fits the
  # last byte of every sequence that allows it, so a reverse DFA state for
  # `\w` or `\p{L}` would hold hundreds of NFA states. Each recorded class
  # (`Program::ClassBlock`) is therefore rebuilt as a trie of its reversed
  # sequences (`ReversedClass`), as Rust regex compiles its
  # reverse NFA: its root is the class's exit, its leaves lead to the
  # class's entry, and the class's own states get no edges. A class whose
  # reversed trie would pass `REVERSED_NODES_PER_STATE` nodes per state of
  # the class keeps its turned-around edges, so building stays O(m).
  class ReverseNFA
    getter start_node : Int32
    getter accept_node : Int32
    @epsilon_offsets : Array(Int32)
    @epsilon_targets : Array(Int32)
    @epsilon_looks : Array(Int32)
    @byte_offsets : Array(Int32)
    @list_of_byte_edges : Array(Program::Transition)

    # The most reversed-trie nodes a class may take per state it compiled
    # to.
    REVERSED_NODES_PER_STATE = 8

    # With *reverse_classes*, each recorded class is read backward through
    # its `ReversedClass` (see the class description).
    def initialize(program : Program, reverse_classes : Bool = false)
      states = program.list_of_states
      @accept_node = program.start_state
      @start_node = states.index(&.kind.match?) || raise Mica::Error.new("internal error: the program has no match state")
      # Byte edges as {node, transition}, epsilon edges as {node, target, look}.
      list_of_byte_edges = [] of {Int32, Program::Transition}
      list_of_epsilon_edges = [] of {Int32, Int32, Int32}
      reversed = Array(Bool).new(states.size, false)
      node_count = states.size
      if reverse_classes
        closed = closed_blocks(program)
        program.list_of_class_blocks.each_with_index do |block, index|
          next unless closed[index]
          node_count = ReverseNFA.reverse_class(program, block, node_count, list_of_byte_edges, reversed)
        end
      end
      each_forward_edge(program) do |source, target, look, low, high|
        if look == BYTE_EDGE
          list_of_byte_edges << {target, Program::Transition.new(low, high, source)} unless reversed[source]
        else
          list_of_epsilon_edges << {target, source, look}
        end
      end
      @epsilon_offsets = Array(Int32).new(node_count + 1, 0)
      @byte_offsets = Array(Int32).new(node_count + 1, 0)
      list_of_epsilon_edges.each { |node, _, _| @epsilon_offsets[node + 1] += 1 }
      list_of_byte_edges.each { |node, _| @byte_offsets[node + 1] += 1 }
      node_count.times do |index|
        @epsilon_offsets[index + 1] += @epsilon_offsets[index]
        @byte_offsets[index + 1] += @byte_offsets[index]
      end
      epsilon_fill = @epsilon_offsets.dup
      byte_fill = @byte_offsets.dup
      @epsilon_targets = Array(Int32).new(list_of_epsilon_edges.size, 0)
      @epsilon_looks = Array(Int32).new(list_of_epsilon_edges.size, 0)
      list_of_epsilon_edges.each do |node, target, look|
        @epsilon_targets[epsilon_fill[node]] = target
        @epsilon_looks[epsilon_fill[node]] = look
        epsilon_fill[node] += 1
      end
      @list_of_byte_edges = Array(Program::Transition).new(list_of_byte_edges.size, Program::Transition.new(0_u8, 0_u8, 0))
      list_of_byte_edges.each do |node, transition|
        @list_of_byte_edges[byte_fill[node]] = transition
        byte_fill[node] += 1
      end
    end

    # Adds the reversed class of *block* (`ReversedClass`) to
    # *list_of_byte_edges*, numbering its new nodes from *node_count*,
    # marks the class's states in *reversed* (their forward byte edges are
    # then left out), and returns the new node count. Leaves everything as
    # it was when the block is not a plain class or its reversed form
    # would be too large.
    protected def self.reverse_class(program : Program, block : Program::ClassBlock, node_count : Int32,
                                     list_of_byte_edges : Array({Int32, Program::Transition}),
                                     reversed : Array(Bool)) : Int32
      budget = REVERSED_NODES_PER_STATE * (block.end_state - block.first_state)
      reversed_class = ReversedClass.for(program, block, budget)
      return node_count unless reversed_class
      (block.first_state...block.end_state).each { |state| reversed[state] = true }
      reversed_class.list_of_edges.each do |node, low, high, target|
        source = node == 0 ? block.exit : node_count + node - 1
        destination = target == ReversedClass::ENTRY ? block.entry : node_count + target - 1
        list_of_byte_edges << {source, Program::Transition.new(low, high, destination)}
      end
      node_count + reversed_class.node_count - 1
    end

    # For each recorded class, whether nothing outside it leads into it
    # but to its entry (a repetition may copy a class's states rather than
    # compile it again; a copy that led into the original's inner states
    # would lose its paths once those states have no reverse edges).
    private def closed_blocks(program : Program) : Array(Bool)
      blocks = program.list_of_class_blocks
      closed = Array(Bool).new(blocks.size, true)
      block_of = Array(Int32).new(program.state_count, -1)
      blocks.each_with_index do |block, index|
        (block.first_state...block.end_state).each { |state| block_of[state] = index }
      end
      each_forward_edge(program) do |source, target, _, _, _|
        index = block_of[target]
        next if index < 0 || block_of[source] == index || target == blocks[index].entry
        closed[index] = false
      end
      closed
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
