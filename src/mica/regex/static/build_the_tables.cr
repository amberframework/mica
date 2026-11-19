require "../../regex"

module Mica::Regex::Static
  # The tables of one direction's complete DFA, as `WriteTheSource` writes
  # them into the application's source. Entries are state ids, and the row
  # of state `s` starts at `s << shift` (rows are a power of two at least
  # the symbol count). States are numbered dead first (0 the dead state, 1
  # the dead state that reports a match), then the other match states,
  # then the accelerated states, then the rest, so the search loop tells
  # every state that needs a look by one comparison against `accel_limit`.
  # `list_of_accel_bytes` holds each accelerated state's `StaticByteScan`
  # code.
  record DirectionTables,
    shift : Int32,
    state_count : Int32,
    list_of_entries : Array(Int32),
    list_of_starts : Array(Int32),
    relevant_flags : Int32,
    context_mask : Int32,
    special_limit : Int32,
    accel_limit : Int32,
    list_of_accel_bytes : Array(Int32) do
    # The largest state id, which picks the table's integer width.
    def largest_entry : Int32
      state_count - 1
    end
  end

  # The NFA a static pattern's capture pass runs (a Pike VM over the match
  # span alone), flattened: `Sparse` states point into the three transition
  # lists, with their targets resolved to state numbers.
  record NfaTables,
    list_of_kinds : Array(Int32),
    list_of_lows : Array(Int32),
    list_of_highs : Array(Int32),
    list_of_next_states : Array(Int32),
    list_of_alternates : Array(Int32),
    list_of_arguments : Array(Int32),
    list_of_sparse_lows : Array(Int32),
    list_of_sparse_highs : Array(Int32),
    list_of_sparse_targets : Array(Int32),
    start_state : Int32 do
    # The largest state number or list index the program holds, which
    # picks its integer width.
    def largest_entry : Int32
      {list_of_next_states, list_of_alternates, list_of_arguments, list_of_sparse_targets}.max_of { |list| list.max? || 0 }
    end
  end

  # The one-pass DFA the capture pass reads first (see `OnePassDFA`):
  # per cell its step (target row shifted left by two, with the edge and
  # match bits) and edge index, per state its match edge and whether every
  # ASCII byte loops back, and per edge the slots it saves and the
  # assertions it checks.
  record OnePassTables,
    list_of_steps : Array(Int32),
    list_of_cells : Array(Int32),
    list_of_match_edges : Array(Int32),
    list_of_edge_slots : Array(UInt64),
    list_of_edge_looks : Array(UInt32),
    list_of_ascii_loops : Array(Int32),
    class_count : Int32

  # Everything one static pattern needs at run time.
  record PatternTables,
    source : String,
    options : CompileOptions,
    list_of_classes : Array(Int32),
    forward : DirectionTables,
    reverse : DirectionTables,
    nfa : NfaTables?,
    one_pass : OnePassTables?,
    unicode_words : Bool,
    final_lf : Bool,
    anchored_start : Bool,
    program_state_count : Int32,
    slot_count : Int32,
    scratch_words : Int32

  # Why a pattern stays on the runtime engine. With *compile_error*, the
  # runtime compiler rejects the pattern too, and the application's build
  # fails at the call.
  record Refusal, source : String, options : CompileOptions, reason : String, compile_error : Bool = false

  # When a pattern is compiled while the application builds, then it is
  # compiled by the runtime compiler under `CompileLimits::TRUSTED_PATTERN`,
  # its forward and reverse lazy DFAs are explored to completion (every
  # start state, every symbol), and the result is renumbered and returned
  # as `PatternTables`; a pattern the static path cannot hold returns a
  # `Refusal` naming why.
  class BuildTheTables
    # The most states one direction's DFA may have.
    MAX_DFA_STATES = 4_096
    # The most bytes the two transition tables may take together.
    MAX_TABLE_BYTES = 512 * 1024
    # The most 32-bit words the capture pass's stack scratch may take
    # (64 KiB).
    MAX_SCRATCH_WORDS = 16_384
    # A budget no exploration reaches; the state caps above bound it.
    UNLIMITED = SearchLimits.custom(work_ceiling: Int64::MAX, work_per_byte: 0_i64, work_per_state: 0_i64,
      base_work: Int64::MAX, max_output_bytes: 0_i64)
    # The options a static pattern may carry: the ones a pattern can also
    # set inline.
    SUPPORTED_OPTIONS = CompileOptions::INLINE

    getter states_explored = 0

    def initialize(@source : String, @options : CompileOptions)
    end

    def perform : PatternTables | Refusal
      outside = @options & ~SUPPORTED_OPTIONS
      return refuse("the options #{outside} have no static form") unless outside.none?
      expression = begin
        Mica::Regex.compile(@source, dialect: :crystal, compile_limits: CompileLimits::TRUSTED_PATTERN, options: @options)
      rescue error : SyntaxError | CompileLimitError
        return Refusal.new(@source, @options, "Mica::Regex.static: #{error.message}", compile_error: true)
      end
      program = expression.program
      return refuse("it uses \\G, which the DFAs leave to the Pike VM") unless LazyDFA.supports?(program)
      byte_classes = ByteClasses.new(program)
      forward_dfa = LazyDFA.new(program, byte_classes, false)
      reverse_dfa = LazyDFA.new(program, byte_classes, true)
      forward = explore(program, forward_dfa, byte_classes, accelerate: true)
      return forward if forward.is_a?(Refusal)
      reverse = explore(program, reverse_dfa, byte_classes, accelerate: true)
      return reverse if reverse.is_a?(Refusal)
      table_bytes = table_bytes_of(forward) + table_bytes_of(reverse)
      if table_bytes > MAX_TABLE_BYTES
        return refuse("its tables take #{table_bytes} bytes, over the static limit of #{MAX_TABLE_BYTES}")
      end
      nfa = nil
      one_pass = nil
      scratch_words = 2
      if program.capture_count > 0
        scratch_words = StaticScratch.words_for(program.state_count, program.slot_count)
        if scratch_words > MAX_SCRATCH_WORDS
          return refuse("its capture pass needs #{scratch_words * 4} bytes of stack, over #{MAX_SCRATCH_WORDS * 4}")
        end
        nfa = flatten(program)
        if BuildTheTables.width_of(nfa.largest_entry) > 2
          return refuse("its capture program needs state numbers over #{UInt16::MAX}")
        end
        one_pass = one_pass_of(program, byte_classes)
      end
      list_of_classes = Array(Int32).new(256) { |byte| byte_classes.class_of(byte.to_u8) }
      PatternTables.new(source: @source, options: @options, list_of_classes: list_of_classes, forward: forward,
        reverse: reverse, nfa: nfa, one_pass: one_pass, unicode_words: forward_dfa.unicode_words?, final_lf: forward_dfa.final_lf?,
        anchored_start: SearchPlan.anchored_start?(program), program_state_count: program.state_count,
        slot_count: program.slot_count, scratch_words: scratch_words)
    end

    # The bytes per entry for numbers up to *largest*: 1 or 2, or 4 for a
    # number the static path does not hold.
    def self.width_of(largest : Int32) : Int32
      return 1 if largest <= UInt8::MAX
      return 2 if largest <= UInt16::MAX
      4
    end

    private def table_bytes_of(tables : DirectionTables) : Int32
      tables.list_of_entries.size * BuildTheTables.width_of(tables.largest_entry)
    end

    private def refuse(reason : String) : Refusal
      Refusal.new(@source, @options, reason)
    end

    # Builds every state of *dfa* reachable from any start state.
    private def explore(program : Program, dfa : LazyDFA, byte_classes : ByteClasses,
                        accelerate : Bool) : DirectionTables | Refusal
      pool = CachePool.new(max_bytes: Int64::MAX // 4, max_cache_bytes: Int64::MAX // 8)
      cache = DFACache.reserve?(dfa, pool) { DFABuilder.new(dfa.node_count) }
      return refuse("no DFA cache could be reserved") unless cache
      meter = SearchMeter.new(UNLIMITED, program.state_count, 0, nil)
      symbols = dfa.symbol_count
      relevant = dfa.relevant_flags
      context_mask = relevant & ~(LazyDFA::MATCH_BEHIND | LazyDFA::UNANCHORED | LazyDFA::START_PENDING)
      list_of_bits = (0...LazyDFA::START_FLAG_COUNT.bit_length).map { |bit| 1 << bit }.select { |bit| context_mask & bit != 0 }
      list_of_start_ids = [] of Int32
      (1 << list_of_bits.size).times do |combination|
        flags = 0
        list_of_bits.each_with_index { |bit, index| flags |= bit if combination.bit(index) == 1 }
        modes = dfa.reverse? ? [0] : [LazyDFA::UNANCHORED, LazyDFA::START_PENDING]
        modes.each do |mode|
          id = cache.start_state(dfa, flags | mode, meter)
          return refuse("the DFA gave up building a start state") if id < 0
          list_of_start_ids << id
        end
      end
      transitions = [] of Int32
      list_of_pending = list_of_start_ids.uniq
      known = Set(Int32).new(list_of_pending)
      known << LazyDFA::DEAD << LazyDFA::DEAD_MATCH
      highest = Math.max(LazyDFA::DEAD_MATCH, list_of_pending.max)
      while id = list_of_pending.pop?
        next if id <= LazyDFA::DEAD_MATCH
        symbols.times do |symbol|
          target = cache.transition(dfa, id, symbol, meter)
          return refuse("the DFA gave up while it was explored") if target < 0
          highest = target if target > highest
          return refuse("its #{dfa.reverse? ? "reverse" : "forward"} DFA has more than #{MAX_DFA_STATES} states") if highest >= MAX_DFA_STATES
          required = (highest + 1) * symbols
          transitions.concat(Array(Int32).new(required - transitions.size, 0)) if transitions.size < required
          transitions[id * symbols + symbol] = target
          list_of_pending << target if known.add?(target)
        end
      end
      return refuse("the DFA cache was cleared while it was explored") if cache.clears > 0
      state_count = highest + 1
      transitions.concat(Array(Int32).new(state_count * symbols - transitions.size, 0)) if transitions.size < state_count * symbols
      @states_explored += state_count
      renumber(cache, dfa, byte_classes, transitions, state_count, symbols, list_of_start_ids, relevant, context_mask,
        accelerate)
    end

    # Orders the states dead, match, accelerated, rest, and writes the
    # table with state-id entries in rows of `1 << shift`.
    private def renumber(cache : DFACache, dfa : LazyDFA, byte_classes : ByteClasses, transitions : Array(Int32),
                         state_count : Int32, symbols : Int32, list_of_start_ids : Array(Int32), relevant : Int32,
                         context_mask : Int32, accelerate : Bool) : DirectionTables
      marks = cache.list_of_marks
      match_ids = [] of Int32
      accel_ids = [] of Int32
      accel_byte_by_id = {} of Int32 => Int32
      rest_ids = [] of Int32
      (LazyDFA::DEAD_MATCH + 1...state_count).each do |id|
        if marks[id] & LazyDFA::MARK_MATCH != 0
          match_ids << id
        elsif accelerate && (accel = acceleration_of(id, transitions, symbols, byte_classes, dfa))
          accel_ids << id
          accel_byte_by_id[id] = accel
        else
          rest_ids << id
        end
      end
      order = [LazyDFA::DEAD, LazyDFA::DEAD_MATCH] + match_ids + accel_ids + rest_ids
      new_id = Array(Int32).new(state_count, 0)
      order.each_with_index { |id, index| new_id[id] = index }
      shift = symbols <= 1 ? 0 : (symbols - 1).bit_length
      entries = Array(Int32).new(state_count << shift, 0)
      order.each_with_index do |id, index|
        next if id <= LazyDFA::DEAD_MATCH
        symbols.times do |symbol|
          entries[(index << shift) + symbol] = new_id[transitions[id * symbols + symbol]]
        end
      end
      starts = list_of_start_ids.map { |id| new_id[id] }
      special_limit = 2 + match_ids.size
      accel_limit = special_limit + accel_ids.size
      accel_bytes = accel_ids.map { |id| accel_byte_by_id[id] }
      DirectionTables.new(shift: shift, state_count: state_count, list_of_entries: entries, list_of_starts: starts,
        relevant_flags: relevant, context_mask: context_mask, special_limit: special_limit, accel_limit: accel_limit,
        list_of_accel_bytes: accel_bytes)
    end

    # The acceleration of state *id* (see `StaticByteScan`): the one byte
    # that leaves it (found with `memchr`), `StaticByteScan::SKIP_ASCII` when
    # no ASCII byte leaves it, a word-at-a-time scan for up to three ASCII
    # bytes that leave it (and for non-ASCII bytes when any leaves it), or nil.
    private def acceleration_of(id : Int32, transitions : Array(Int32), symbols : Int32, byte_classes : ByteClasses,
                                dfa : LazyDFA) : Int32?
      list_of_ascii_escapes = [] of Int32
      leaves_on_non_ascii = false
      256.times do |byte|
        class_index = byte_classes.class_of(byte.to_u8)
        leaves = transitions[id * symbols + class_index] != id
        if !leaves && dfa.unicode_words? && byte >= 0x80
          leaves = transitions[id * symbols + dfa.word_symbol(class_index)] != id
        end
        next unless leaves
        if byte < 0x80
          list_of_ascii_escapes << byte
          return nil if list_of_ascii_escapes.size > StaticByteScan::MAX_SCAN_BYTES
        else
          leaves_on_non_ascii = true
        end
      end
      return nil if list_of_ascii_escapes.empty? && !leaves_on_non_ascii
      return StaticByteScan::SKIP_ASCII if list_of_ascii_escapes.empty?
      return list_of_ascii_escapes.first if list_of_ascii_escapes.size == 1 && !leaves_on_non_ascii
      StaticByteScan.encode(list_of_ascii_escapes, leaves_on_non_ascii)
    end

    private def one_pass_of(program : Program, byte_classes : ByteClasses) : OnePassTables?
      dfa = OnePassDFA.build(program, byte_classes)
      return nil unless dfa
      steps, cells, match_edges, edges, ascii_loops = dfa.static_parts
      OnePassTables.new(list_of_steps: steps, list_of_cells: cells, list_of_match_edges: match_edges,
        list_of_edge_slots: edges.map(&.slots), list_of_edge_looks: edges.map(&.looks),
        list_of_ascii_loops: ascii_loops.map { |loops| loops ? 1 : 0 }, class_count: byte_classes.class_count)
    end

    private def flatten(program : Program) : NfaTables
      kinds = [] of Int32
      lows = [] of Int32
      highs = [] of Int32
      nexts = [] of Int32
      alternates = [] of Int32
      arguments = [] of Int32
      sparse_lows = [] of Int32
      sparse_highs = [] of Int32
      sparse_targets = [] of Int32
      program.list_of_states.each_with_index do |state, index|
        kinds << state.kind.value.to_i32
        lows << state.low.to_i32
        highs << state.high.to_i32
        nexts << Math.max(state.next_state, 0)
        if state.kind.sparse?
          arguments << sparse_lows.size
          alternates << state.alternate
          state.alternate.times do |offset|
            transition = program.transition_at(index, state, offset)
            sparse_lows << transition.low.to_i32
            sparse_highs << transition.high.to_i32
            sparse_targets << transition.target
          end
        else
          arguments << state.argument
          alternates << Math.max(state.alternate, 0)
        end
      end
      NfaTables.new(list_of_kinds: kinds, list_of_lows: lows, list_of_highs: highs, list_of_next_states: nexts,
        list_of_alternates: alternates, list_of_arguments: arguments, list_of_sparse_lows: sparse_lows,
        list_of_sparse_highs: sparse_highs, list_of_sparse_targets: sparse_targets, start_state: program.start_state)
    end
  end
end
