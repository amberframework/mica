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
  # Only sets of at least `MIN_RANGES` ranges or reaching
  # `MIN_WIDE_CODE_POINT` are kept, and at most
  # `MAX_ENTRIES`; after that, each large class's block is built for the
  # compilation that needs it.
  module ClassMemo
    MIN_RANGES = 16
    # A set that reaches this code point is kept too, however few its
    # ranges: its three- and four-byte sequences make a trie of many nodes
    # (`.` and `[^"']` are two and three ranges, and twenty states).
    MIN_WIDE_CODE_POINT = 0x800
    MAX_ENTRIES         =   256
    # The target that stands for the state after the class.
    EXIT = -2
    # No target.
    NONE = -1
    # No transition holds the byte (in `Block#entry_targets`).
    NO_TRANSITION = Int32::MIN + 1
    # The slot of `Block#entry_targets` past the 256 byte values: where the
    # entry state's transitions begin in the shared table.
    ENTRY_FIRST_SLOT = 256

    # A class automaton: its states and transitions with targets relative
    # to the block (`EXIT` for the exit), and, for a block of the memo,
    # the same transitions as a table programs share
    # (`Program#list_of_shared_tables`): targets relative to the state
    # that holds them, `Program::SHARED_EXIT` for the exit.
    #
    # A memoized block also keeps *entry_targets*: for each byte value, the
    # shared-table target of the entry state's transition that holds it, or
    # `NO_TRANSITION`, so a search reads the lead byte of a sequence with
    # one load (see `Program#sparse_target`), and in slot
    # `ENTRY_FIRST_SLOT` where the entry's transitions begin in the table.
    record Block, list_of_states : Array(Program::State), list_of_transitions : Array(Program::Transition),
      entry : Int32, shared_table : Array(Program::Transition)? = nil, entry_targets : Slice(Int32)? = nil

    # A set as a hash key: the hash is the set's digest, computed once when
    # the set was made, and equality is the same object (the shared sets of
    # `ClassLowering`) or equal bounds, so a lookup costs far less than
    # hashing an `Array(Int32)` element by element. Sets are never changed
    # after they are made, so the key holds the set itself.
    struct Key
      getter set : CodePointSet

      def initialize(@set : CodePointSet)
      end

      def hash(hasher)
        @set.digest.hash(hasher)
      end

      def ==(other : Key) : Bool
        other_set = other.set
        @set.same?(other_set) || (@set.digest == other_set.digest && @set.list_of_bounds == other_set.list_of_bounds)
      end
    end

    @@mutex = Mutex.new
    @@blocks = {} of Key => Block

    def self.memoized?(set : CodePointSet) : Bool
      bounds = set.list_of_bounds
      bounds.size >= MIN_RANGES * 2 || (!bounds.empty? && bounds[-1] >= MIN_WIDE_CODE_POINT)
    end

    # Returns the block for *set* (a memoized set), building it under
    # *ledger* and *meter* the first time: decoded from `Prebuilt` when
    # the set is one of the static sets generated there, else from its
    # trie.
    def self.block_for(set : CodePointSet, ledger : AllocationLedger, meter : Core::WorkMeter) : Block
      lookup = Key.new(set)
      if block = @@mutex.synchronize { @@blocks[lookup]? }
        return block
      end
      block = prebuilt_block?(set, ledger, meter) || build(set, ledger, meter)
      @@mutex.synchronize do
        if existing = @@blocks[lookup]?
          block = existing
        elsif @@blocks.size < MAX_ENTRIES
          @@blocks[lookup] = block
        end
      end
      block
    end

    # :nodoc:
    # Builds *set*'s block from its trie, past the memo and `Prebuilt`
    # (for scripts/generate_class_blocks.cr and the specs).
    def self.build_from_trie(set : CodePointSet) : Block
      build(set, AllocationLedger.new(Int64::MAX), Core::WorkMeter.new)
    end

    # :nodoc:
    # *set*'s block from `Prebuilt`, or nil (for the specs).
    def self.prebuilt_block_of?(set : CodePointSet) : Block?
      prebuilt_block?(set, AllocationLedger.new(Int64::MAX), Core::WorkMeter.new)
    end

    # The bytes of one state in `Prebuilt::DATA`: kind, low, high, then
    # next state, alternate and argument as little-endian Int16.
    PREBUILT_STATE_BYTES = 9
    # The bytes of one transition there: low, high, then the target as a
    # little-endian Int16.
    PREBUILT_TRANSITION_BYTES = 4

    # Returns *set*'s block decoded from `Prebuilt` when the set is the
    # static set (or the complement of one) a prebuilt block was generated
    # for, else nil. A prebuilt block is the one `build` makes for that
    # set (scripts/generate_class_blocks.cr writes it with `build`, and a
    # spec checks them equal), read from static data in one pass of
    # copies: `\w` and `\p{L}` cost tens of microseconds and over 100 KiB
    # of short-lived allocation to build, once per process.
    private def self.prebuilt_block?(set : CodePointSet, ledger : AllocationLedger,
                                     meter : Core::WorkMeter) : Block?
      bounds = set.list_of_bounds
      Prebuilt::LIST_OF_ENTRIES.each do |prebuilt|
        set_id, negated, range_count, entry, state_count, transition_count, offset = prebuilt
        next unless bounds.size == range_count * 2
        next unless static_set?(bounds, set_id, negated, meter)
        return decode_prebuilt(entry, state_count, transition_count, offset, ledger, meter)
      end
      nil
    end

    # True when *bounds* are those of static set *set_id*, or of its
    # complement when *negated*.
    private def self.static_set?(bounds : Array(Int32), set_id : Int32, negated : Bool,
                                 meter : Core::WorkMeter) : Bool
      meter.enforce { Core::Position.new(0_i64) } if meter.charge(bounds.size)
      static = Unicode.decoded_ranges(set_id)
      unless negated
        return false unless static.size == bounds.size
        bounds.each_with_index { |bound, index| return false unless static[index] == bound }
        return true
      end
      # The complement's ranges are the gaps between the static ranges.
      index = 0
      first = 0
      static_index = 0
      while static_index <= static.size
        last = static_index == static.size ? CodePointSet::MAX_CODE_POINT : static[static_index] - 1
        if first <= last
          return false unless index + 1 < bounds.size && bounds[index] == first && bounds[index + 1] == last
          index += 2
        end
        break if static_index == static.size
        first = static[static_index + 1] + 1
        static_index += 2
      end
      index == bounds.size
    end

    private def self.decode_prebuilt(entry : Int32, state_count : Int32, transition_count : Int32, offset : Int32,
                                     ledger : AllocationLedger, meter : Core::WorkMeter) : Block
      meter.enforce { Core::Position.new(0_i64) } if meter.charge(state_count + transition_count)
      prebuilt_bytes = Prebuilt::DATA.to_slice
      ledger.charge_array(state_count, sizeof(Program::State), "a class block", 0)
      list_of_states = Array(Program::State).new(state_count)
      state_count.times do
        list_of_states << Program::State.new(Program::StateKind.new(prebuilt_bytes[offset]), prebuilt_bytes[offset + 1], prebuilt_bytes[offset + 2],
          prebuilt_int(prebuilt_bytes, offset + 3), prebuilt_int(prebuilt_bytes, offset + 5), prebuilt_int(prebuilt_bytes, offset + 7))
        offset += PREBUILT_STATE_BYTES
      end
      ledger.charge_array(transition_count, sizeof(Program::Transition), "a class block", 0)
      list_of_transitions = Array(Program::Transition).new(transition_count)
      transition_count.times do
        list_of_transitions << Program::Transition.new(prebuilt_bytes[offset], prebuilt_bytes[offset + 1], prebuilt_int(prebuilt_bytes, offset + 2))
        offset += PREBUILT_TRANSITION_BYTES
      end
      table = shared_table(list_of_states, list_of_transitions, ledger)
      Block.new(list_of_states, list_of_transitions, entry, table, entry_targets(list_of_states[entry], table, ledger))
    end

    @[AlwaysInline]
    private def self.prebuilt_int(prebuilt_bytes : Bytes, offset : Int32) : Int32
      (prebuilt_bytes[offset].to_i16 | (prebuilt_bytes[offset + 1].to_i16 << 8)).to_i32
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
      table = shared_table(list_of_states, list_of_transitions, ledger)
      entry = node_states[0]
      Block.new(list_of_states, list_of_transitions, entry, table, entry_targets(list_of_states[entry], table, ledger))
    end

    # The target in *table* for each byte value at *entry* (a `Sparse`
    # state; nil for any other), `NO_TRANSITION` where it has none, and
    # the entry's first transition in slot `ENTRY_FIRST_SLOT`.
    private def self.entry_targets(entry : Program::State, table : Array(Program::Transition),
                                   ledger : AllocationLedger) : Slice(Int32)?
      return nil unless entry.kind.sparse?
      ledger.charge(AllocationLedger.granules((ENTRY_FIRST_SLOT + 1) * sizeof(Int32)), "a class entry table", 0)
      targets = Slice(Int32).new(ENTRY_FIRST_SLOT + 1, NO_TRANSITION)
      targets[ENTRY_FIRST_SLOT] = entry.argument
      entry.alternate.times do |offset|
        transition = table[entry.argument + offset]
        (transition.low..transition.high).each { |byte| targets[byte] = transition.target }
      end
      targets
    end

    # The transitions of a block as a shared table: each target relative
    # to the `Sparse` state that holds it, the exit as `SHARED_EXIT`.
    private def self.shared_table(list_of_states : Array(Program::State), list_of_transitions : Array(Program::Transition),
                                  ledger : AllocationLedger) : Array(Program::Transition)
      ledger.charge_array(list_of_transitions.size, sizeof(Program::Transition), "a shared class table", 0)
      table = list_of_transitions.dup
      list_of_states.each_with_index do |state, index|
        next unless state.kind.sparse?
        state.alternate.times do |offset|
          position = state.argument + offset
          target = table[position].target
          table[position] = table[position].copy_with(target: target == EXIT ? Program::SHARED_EXIT : target - index)
        end
      end
      table
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
