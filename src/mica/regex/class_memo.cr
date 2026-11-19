module Mica::Regex
  # :nodoc:
  # A process-wide memo of large classes compiled to byte automata, so a
  # class such as `\w` or `\p{L}` (hundreds of ranges) is split into UTF-8
  # sequences and minimized once per process rather than once per pattern
  # or per repetition copy. It plays the part PCRE2's static property
  # tables play.
  #
  # A large class compiles to a minimal acyclic automaton: its byte trie
  # (`ClassTrie`) with equal suffixes merged, so the many sequences that
  # end in the same continuation-byte ranges share their last states. The
  # automaton is held as a `Block` of states and transitions with targets
  # relative to the block and the class's exit marked `EXIT`; the compiler
  # copies it into a program, and the size preflight takes its exact state
  # count as the class's bound. A block depends only on the set, so a
  # program is the same whether its blocks came from the memo or were
  # built for it.
  #
  # Only sets of at least `MIN_RANGES` ranges are kept, and at most
  # `MAX_ENTRIES`; after that, each large class's block is built for the
  # compilation that needs it.
  module ClassMemo
    MIN_RANGES  =  16
    MAX_ENTRIES = 256
    # The target that stands for the state after the class.
    EXIT = -2
    # No target.
    NONE = -1

    record Block, list_of_states : Array(Program::State), list_of_transitions : Array(Program::Transition),
      entry : Int32

    # A set's bounds as a hash key: the hash is the set's digest, computed
    # once when the set was made, and equality is a `memcmp`, so a lookup
    # costs far less than hashing an `Array(Int32)` element by element.
    struct Key
      getter bounds : Slice(Int32)
      @digest : UInt64

      def initialize(@bounds : Slice(Int32), @digest : UInt64)
      end

      def hash(hasher)
        @digest.hash(hasher)
      end

      def ==(other : Key) : Bool
        @digest == other.@digest && @bounds == other.bounds
      end

      # A copy that owns its bounds, for storing.
      def stored : Key
        Key.new(@bounds.dup, @digest)
      end
    end

    @@mutex = Mutex.new
    @@blocks = {} of Key => Block

    private def self.key(set : CodePointSet) : Key
      bounds = set.list_of_bounds
      Key.new(Slice.new(bounds.to_unsafe, bounds.size, read_only: true), set.digest)
    end

    def self.memoized?(set : CodePointSet) : Bool
      set.range_count >= MIN_RANGES
    end

    # Returns the block for *set* (a memoized set), building it under
    # *ledger* and *meter* the first time.
    def self.block_for(set : CodePointSet, ledger : AllocationLedger, meter : Core::WorkMeter) : Block
      lookup = key(set)
      if block = @@mutex.synchronize { @@blocks[lookup]? }
        return block
      end
      block = build(set, ledger, meter)
      stored = lookup.stored
      @@mutex.synchronize do
        if existing = @@blocks[stored]?
          block = existing
        elsif @@blocks.size < MAX_ENTRIES
          @@blocks[stored] = block
        end
      end
      block
    end

    # Builds the minimal automaton of *set*: the trie's nodes are emitted
    # from the last back (children before parents), and a node whose edges
    # and targets equal a node already emitted reuses that node's state.
    private def self.build(set : CodePointSet, ledger : AllocationLedger, meter : Core::WorkMeter) : Block
      ClassTrie.charge_new(ledger)
      trie = ClassTrie.new
      trie.build(set, ledger, meter)
      ledger.charge_array(0, sizeof(Program::State), "a class block", 0)
      list_of_states = [] of Program::State
      ledger.charge_array(0, sizeof(Program::Transition), "a class block", 0)
      list_of_transitions = [] of Program::Transition
      if trie.empty?
        ledger.charge_append(sizeof(Program::State), "a class block", 0)
        list_of_states << Program::State.new(Program::StateKind::Fail, 0_u8, 0_u8, NONE, NONE, 0)
        return Block.new(list_of_states, list_of_transitions, 0)
      end
      node_count = trie.node_count
      ledger.charge_array(node_count, sizeof(Int32), "a class block", 0)
      node_states = Array(Int32).new(node_count, NONE)
      ledger.charge_object(instance_sizeof(Hash(UInt64, Int32)), "a class block", 0)
      shared_nodes = {} of UInt64 => Int32
      builder = BlockBuilder.new(trie, node_states, list_of_states, list_of_transitions, ledger, meter)
      (node_count - 1).downto(0) do |node_index|
        digest = builder.digest(node_index)
        existing = shared_nodes[digest]?
        if existing && builder.same_edges?(existing, node_index)
          node_states[node_index] = existing
          next
        end
        state = builder.emit(node_index)
        node_states[node_index] = state
        next if existing
        ledger.charge_hash_entry(sizeof(UInt64) + sizeof(Int32), "a class block", 0)
        shared_nodes[digest] = state
      end
      Block.new(list_of_states, list_of_transitions, node_states[0])
    end

    # Emits trie nodes into a block's lists.
    private struct BlockBuilder
      def initialize(@trie : ClassTrie, @node_states : Array(Int32), @list_of_states : Array(Program::State),
                     @list_of_transitions : Array(Program::Transition), @ledger : AllocationLedger,
                     @meter : Core::WorkMeter)
      end

      # The block target of *edge*: `EXIT` for a sequence's last byte, else
      # the state of the node it leads to (already emitted).
      def target(edge : ClassTrie::Edge) : Int32
        edge.child == ClassTrie::LEAF ? EXIT : @node_states[edge.child]
      end

      # An FNV-1a digest of the node's edges and their targets.
      def digest(node_index : Int32) : UInt64
        digest = 14695981039346656037_u64
        edge_index = @trie.list_of_nodes[node_index][0]
        while edge_index != ClassTrie::NONE
          edge = @trie.list_of_edges[edge_index]
          @meter.enforce { Core::Position.new(0_i64) } if @meter.charge(1)
          word = edge.low.to_u64 | (edge.high.to_u64 << 8) | (target(edge).to_u32!.to_u64 << 16)
          digest = (digest ^ word) &* 1099511628211_u64
          edge_index = edge.next_sibling
        end
        digest
      end

      # Returns true when block state *state_index* has exactly the edges of
      # trie node *node_index*.
      def same_edges?(state_index : Int32, node_index : Int32) : Bool
        state = @list_of_states[state_index]
        edge_index = @trie.list_of_nodes[node_index][0]
        if state.kind.byte_range?
          edge = @trie.list_of_edges[edge_index]
          return edge.next_sibling == ClassTrie::NONE && edge.low == state.low && edge.high == state.high &&
            target(edge) == state.next_state
        end
        position = state.argument
        stop = position + state.alternate
        while edge_index != ClassTrie::NONE
          return false if position == stop
          edge = @trie.list_of_edges[edge_index]
          transition = @list_of_transitions[position]
          return false unless transition.low == edge.low && transition.high == edge.high &&
                              transition.target == target(edge)
          position += 1
          edge_index = edge.next_sibling
        end
        position == stop
      end

      # Emits the node as a `ByteRange` state (one edge) or a `Sparse` state
      # (several) and returns its index.
      def emit(node_index : Int32) : Int32
        first_edge, last_edge = @trie.list_of_nodes[node_index]
        @ledger.charge_append(sizeof(Program::State), "a class block", 0)
        if first_edge == last_edge
          edge = @trie.list_of_edges[first_edge]
          @list_of_states << Program::State.new(Program::StateKind::ByteRange, edge.low, edge.high, target(edge), NONE, 0)
          return @list_of_states.size - 1
        end
        first_transition = @list_of_transitions.size
        count = 0
        edge_index = first_edge
        while edge_index != ClassTrie::NONE
          edge = @trie.list_of_edges[edge_index]
          @ledger.charge_append(sizeof(Program::Transition), "a class block", 0)
          @list_of_transitions << Program::Transition.new(edge.low, edge.high, target(edge))
          count += 1
          edge_index = edge.next_sibling
        end
        @list_of_states << Program::State.new(Program::StateKind::Sparse, 0_u8, 0_u8, NONE, count, first_transition)
        @list_of_states.size - 1
      end
    end
  end
end
