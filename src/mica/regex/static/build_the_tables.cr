require "../../regex"
require "./build_the_decoder_product"

module Mica::Regex::Static
  # The tables of one direction's complete DFA, as `WriteTheSource` writes
  # them into the application's source. Entries are state ids, and the row
  # of state `s` starts at `s << shift` (rows are a power of two at least
  # the symbol count). A byte's column is `list_of_columns[byte]` (the byte
  # classes, or the columns of a table read over UTF-8 decoder states, see
  # `BuildTheDecoderProduct`), the edge columns start at `edge_symbol` and
  # the Unicode-word columns at `word_offset`. States are numbered dead
  # first (0 the dead state, 1 the dead state that reports a match), then
  # the other match states,
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
    list_of_accel_bytes : Array(Int32),
    list_of_columns : Array(Int32),
    edge_symbol : Int32,
    word_offset : Int32 do
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
    list_of_class_targets : Array(Int32),
    class_count : Int32,
    start_state : Int32 do
    # The largest state number or list index the program holds, which
    # picks its integer width.
    def largest_entry : Int32
      {list_of_next_states, list_of_alternates, list_of_arguments, list_of_sparse_targets, list_of_class_targets}.max_of { |list| list.max? || 0 }
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

  # The literal prefilter a static pattern searches with (see
  # `StaticPrefilter`): the runtime engine's `Prefilter` for the
  # pattern's prefix literals, its choices written out as tables. The
  # pair tests take `StaticPrefilter::WORDS_PER_TEST` words each.
  record PrefilterTables,
    kind : Int32,
    exact : Bool,
    list_of_literal_bytes : Array(Int32),
    list_of_literal_ends : Array(Int32),
    list_of_starting_with : Array(UInt64),
    list_of_words : Array(UInt64),
    list_of_word_masks : Array(UInt64),
    needle : Int32,
    needle_offset : Int32,
    pair_gap : Int32,
    mask_width : Int32,
    list_of_masks : Array(UInt64),
    minimum_length : Int32,
    list_of_pair_tests : Array(UInt64),
    list_of_narrow_tests : Array(UInt64),
    list_of_dense_tests : Array(UInt64) do
    # True when every literal is one byte (`,` in `,\s*`): the literals are
    # then the bytes a match starts with, and a start scan
    # (`StaticMatcher#find_at_start_bytes`) finds them with no literal to
    # verify.
    def one_byte_literals? : Bool
      list_of_literal_ends.each_with_index.all? { |literal_end, index| literal_end == index + 1 }
    end
  end

  # Everything one static pattern needs at run time.
  record PatternTables,
    source : String,
    options : CompileOptions,
    list_of_classes : Array(Int32),
    forward : DirectionTables,
    reverse : DirectionTables,
    nfa : NfaTables?,
    one_pass : OnePassTables?,
    prefilter : PrefilterTables?,
    list_of_required_bytes : Array(Int32),
    minimum_bytes : Int32,
    start_scan : Int32,
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
    # The most states one direction's table may have: its ids fit `UInt16`.
    MAX_DFA_STATES = UInt16::MAX.to_i32 + 1
    # The most bytes the two transition tables may take together.
    MAX_TABLE_BYTES = 512 * 1024
    # The most bytes one direction's table may reach, in rows of every
    # symbol with `UInt16` ids, while its DFA is explored: twice the limit,
    # as a table read over UTF-8 decoder states (`BuildTheDecoderProduct`)
    # can take half the bytes.
    EXPLORE_TABLE_BYTES = 2 * MAX_TABLE_BYTES
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

    # With *always_decoder_columns*, every table is read over UTF-8 decoder
    # states (see `BuildTheDecoderProduct`), not only one that is too wide
    # otherwise: the static differential runs that way to cover the layout
    # with every pattern.
    def initialize(@source : String, @options : CompileOptions, @always_decoder_columns : Bool = false)
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
      explored_forward = explore(program, forward_dfa)
      return explored_forward if explored_forward.is_a?(Refusal)
      explored_reverse = explore(program, reverse_dfa)
      return explored_reverse if explored_reverse.is_a?(Refusal)
      forward = plain_tables(explored_forward, byte_classes)
      reverse = plain_tables(explored_reverse, byte_classes)
      if @always_decoder_columns
        forward = decoder_tables(explored_forward, byte_classes)
        reverse = decoder_tables(explored_reverse, byte_classes)
      elsif table_bytes_of(forward) + table_bytes_of(reverse) > MAX_TABLE_BYTES
        # Too wide: each direction read over UTF-8 decoder states, where
        # that takes fewer bytes.
        forward = narrower(forward, decoder_tables(explored_forward, byte_classes))
        reverse = narrower(reverse, decoder_tables(explored_reverse, byte_classes))
      end
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
        nfa = flatten(program, byte_classes)
        if BuildTheTables.width_of(nfa.largest_entry) > 2
          return refuse("its capture program needs state numbers over #{UInt16::MAX}")
        end
        one_pass = one_pass_of(program, byte_classes)
      end
      list_of_classes = Array(Int32).new(256) { |byte| byte_classes.class_of(byte.to_u8) }
      anchored_start = SearchPlan.anchored_start?(program)
      prefilter = anchored_start ? nil : prefilter_of(program)
      start_filter = StartFilter.new(program)
      start_scan = start_scan_of(start_filter, anchored_start, prefilter)
      prefilter = nil unless start_scan == StaticMatcher::NO_START_SCAN
      PatternTables.new(source: @source, options: @options, list_of_classes: list_of_classes, forward: forward,
        reverse: reverse, nfa: nfa, one_pass: one_pass, prefilter: prefilter,
        list_of_required_bytes: required_bytes_of(program, forward), minimum_bytes: start_filter.minimum_bytes,
        start_scan: start_scan,
        unicode_words: forward_dfa.unicode_words?, final_lf: forward_dfa.final_lf?,
        anchored_start: anchored_start, program_state_count: program.state_count,
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

    # One direction's DFA, explored: every state reachable from a start
    # state, `symbols` transitions each (state-major), and the start states
    # in `StaticDirection#starts` order.
    record ExploredDirection,
      dfa : LazyDFA,
      list_of_transitions : Array(Int32),
      state_count : Int32,
      symbols : Int32,
      list_of_start_ids : Array(Int32),
      list_of_match : Array(Bool),
      relevant_flags : Int32,
      context_mask : Int32

    # Builds every state of *dfa* reachable from any start state; refuses
    # once the table, in rows of every symbol with `UInt16` ids, would pass
    # `EXPLORE_TABLE_BYTES`, or its ids would not fit `UInt16`.
    private def explore(program : Program, dfa : LazyDFA) : ExploredDirection | Refusal
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
      state_cap = Math.min(MAX_DFA_STATES, EXPLORE_TABLE_BYTES // (2 * row_width(symbols)))
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
          return refuse("its #{dfa.reverse? ? "reverse" : "forward"} DFA has more than #{state_cap} states") if highest >= state_cap
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
      marks = cache.list_of_marks
      list_of_match = Array(Bool).new(state_count) { |id| id > LazyDFA::DEAD_MATCH && marks[id] & LazyDFA::MARK_MATCH != 0 }
      ExploredDirection.new(dfa: dfa, list_of_transitions: transitions, state_count: state_count, symbols: symbols,
        list_of_start_ids: list_of_start_ids, list_of_match: list_of_match, relevant_flags: relevant,
        context_mask: context_mask)
    end

    # The columns of a row of *symbols* symbols: the next power of two.
    private def row_width(symbols : Int32) : Int32
      symbols <= 1 ? 1 : 1 << (symbols - 1).bit_length
    end

    # The table of *explored* with a column per byte class.
    private def plain_tables(explored : ExploredDirection, byte_classes : ByteClasses) : DirectionTables
      dfa = explored.dfa
      transitions = explored.list_of_transitions
      symbols = explored.symbols
      list_of_weights = Array(Int32).new(symbols, 0)
      byte_classes.class_count.times { |class_index| list_of_weights[class_index] = byte_classes.class_size(class_index) }
      list_of_accel = Array(Int32?).new(explored.state_count) do |id|
        next nil if id <= LazyDFA::DEAD_MATCH || explored.list_of_match[id]
        acceleration_of(id, transitions, symbols, byte_classes, dfa)
      end
      list_of_columns = Array(Int32).new(256) { |byte| byte_classes.class_of(byte.to_u8) }
      renumber(explored, transitions, explored.state_count, symbols, explored.list_of_start_ids, explored.list_of_match,
        list_of_accel, Array(Array(Int32)).new(explored.state_count, list_of_weights), list_of_columns,
        byte_classes.class_count, byte_classes.class_count + 2)
    end

    # The table of *explored* read over UTF-8 decoder states (see
    # `BuildTheDecoderProduct`). A state between characters keeps its DFA
    # state's acceleration: its scan stops at an ASCII byte or at every
    # non-ASCII byte, so it stops between characters, where the state is
    # read. A state inside a character is not accelerated.
    private def decoder_tables(explored : ExploredDirection, byte_classes : ByteClasses) : DirectionTables
      dfa = explored.dfa
      product = BuildTheDecoderProduct.new(explored.list_of_transitions, explored.symbols, explored.list_of_start_ids,
        byte_classes, dfa).perform
      accel_by_dfa_id = {} of Int32 => Int32?
      list_of_match = Array(Bool).new(product.state_count) { |id| explored.list_of_match[product.list_of_dfa_ids[id]] }
      list_of_accel = Array(Int32?).new(product.state_count) do |id|
        dfa_id = product.list_of_dfa_ids[id]
        next nil if id <= LazyDFA::DEAD_MATCH || list_of_match[id]
        next nil unless product.list_of_decoder_states[id] == BuildTheDecoderProduct::BETWEEN
        accel_by_dfa_id.fetch(dfa_id) do
          accel_by_dfa_id[dfa_id] = acceleration_of(dfa_id, explored.list_of_transitions, explored.symbols, byte_classes, dfa)
        end
      end
      weights_by_decoder_state = {} of Int32 => Array(Int32)
      list_of_weights = Array(Array(Int32)).new(product.state_count) do |id|
        decoder_state = product.list_of_decoder_states[id]
        weights_by_decoder_state[decoder_state] ||= begin
          list_of_column_weights = Array(Int32).new(product.symbols, 0)
          256.times do |byte|
            role = BuildTheDecoderProduct.utf8_role(byte)
            next unless BuildTheDecoderProduct.readable?(dfa.reverse?, decoder_state, role)
            list_of_column_weights[product.list_of_columns[byte]] += 1
          end
          list_of_column_weights
        end
      end
      renumber(explored, product.list_of_transitions, product.state_count, product.symbols, product.list_of_start_ids,
        list_of_match, list_of_accel, list_of_weights, product.list_of_columns, product.edge_symbol, product.word_offset)
    end

    # The one of *plain* and *decoder* that takes fewer bytes.
    private def narrower(plain : DirectionTables, decoder : DirectionTables) : DirectionTables
      table_bytes_of(decoder) < table_bytes_of(plain) ? decoder : plain
    end

    # Orders the states dead, match, accelerated, rest, and writes the
    # table with state-id entries in rows of `1 << shift`.
    private def renumber(explored : ExploredDirection, transitions : Array(Int32), state_count : Int32, symbols : Int32,
                         list_of_start_ids : Array(Int32), list_of_match : Array(Bool), list_of_accel : Array(Int32?),
                         list_of_weights : Array(Array(Int32)), list_of_columns : Array(Int32), edge_symbol : Int32,
                         word_offset : Int32) : DirectionTables
      match_ids = [] of Int32
      accel_ids = [] of Int32
      rest_ids = [] of Int32
      (LazyDFA::DEAD_MATCH + 1...state_count).each do |id|
        if list_of_match[id]
          match_ids << id
        elsif list_of_accel[id]
          accel_ids << id
        else
          rest_ids << id
        end
      end
      rest_ids = in_chains(rest_ids, transitions, symbols, list_of_weights)
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
      accel_bytes = accel_ids.map { |id| list_of_accel[id] || 0 }
      DirectionTables.new(shift: shift, state_count: state_count, list_of_entries: entries, list_of_starts: starts,
        relevant_flags: explored.relevant_flags, context_mask: explored.context_mask, special_limit: special_limit,
        accel_limit: accel_limit, list_of_accel_bytes: accel_bytes, list_of_columns: list_of_columns,
        edge_symbol: edge_symbol, word_offset: word_offset)
    end

    # The bytes every match contains (`StartFilter#list_of_required_bytes`),
    # which a search looks for before it runs the DFAs; none when the
    # forward DFA's unanchored start states are all accelerated: those
    # already skip to where a match can start as fast as the look would.
    private def required_bytes_of(program : Program, forward : DirectionTables) : Array(Int32)
      starts = forward.list_of_starts
      unanchored = (0...starts.size).step(2).map { |index| starts[index] }
      return [] of Int32 if unanchored.all? { |id| forward.special_limit <= id < forward.accel_limit }
      StartFilter.new(program).list_of_required_bytes.map(&.to_i32)
    end

    # The `StaticByteScan` code that finds the bytes a match can start with
    # (`StartFilter#starts?`), so a search tries the forward DFA anchored at
    # each of them and knows the match's start without the reverse DFA (see
    # `StaticMatcher#find_at_start_bytes`); a pattern that gets one keeps
    # no prefilter. It is `StaticMatcher::NO_START_SCAN` for a pattern
    # anchored at its start, one with a prefilter of longer literals (which
    # finds its candidates its own way), one that can match empty, and for
    # start bytes more than `StaticByteScan::MAX_SCAN_BYTES`, or more than
    # one with a non-ASCII byte among them.
    private def start_scan_of(start_filter : StartFilter, anchored_start : Bool, prefilter : PrefilterTables?) : Int32
      return StaticMatcher::NO_START_SCAN if anchored_start || start_filter.minimum_bytes == 0
      return StaticMatcher::NO_START_SCAN if prefilter && !prefilter.one_byte_literals?
      list_of_start_bytes = (0..255).select { |byte| start_filter.starts?(byte.to_u8) }
      return StaticMatcher::NO_START_SCAN if list_of_start_bytes.empty?
      return list_of_start_bytes.first if list_of_start_bytes.size == 1
      if list_of_start_bytes.size > StaticByteScan::MAX_SCAN_BYTES || list_of_start_bytes.any? { |byte| byte >= 0x80 }
        return StaticMatcher::NO_START_SCAN
      end
      StaticByteScan.encode(list_of_start_bytes, false)
    end

    # *list_of_ids* reordered so a state's main successor (the one most
    # byte values lead to, past the dead states and itself) comes right
    # after it where it can: `[0-9a-f]{8}-` becomes states numbered one
    # after another, and the search loop follows such a chain with loads
    # that do not wait on each other (see `StaticMatcher#find_end`).
    private def in_chains(list_of_ids : Array(Int32), transitions : Array(Int32), symbols : Int32,
                          list_of_weights : Array(Array(Int32))) : Array(Int32)
      members = list_of_ids.to_set
      placed = Set(Int32).new
      ordered = [] of Int32
      list_of_ids.each do |id|
        current = id
        while members.includes?(current) && placed.add?(current)
          ordered << current
          current = main_successor(current, transitions, symbols, list_of_weights[current])
        end
      end
      ordered
    end

    # The successor of state *id* the most byte values lead to, past the
    # dead states and *id* itself, or -1. *list_of_weights* holds the bytes
    # each column stands for at the state.
    private def main_successor(id : Int32, transitions : Array(Int32), symbols : Int32,
                               list_of_weights : Array(Int32)) : Int32
      bytes_by_target = Hash(Int32, Int32).new(0)
      list_of_weights.each_with_index do |weight, column|
        next if weight == 0
        target = transitions[id * symbols + column]
        next if target <= LazyDFA::DEAD_MATCH || target == id
        bytes_by_target[target] += weight
      end
      best = bytes_by_target.max_by? { |target, count| {count, -target} }
      best ? best[0] : -1
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

    # The runtime engine's prefilter for *program*'s prefix literals, as
    # tables, or nil when it has none or needs none: a prefilter that finds
    # up to three first bytes (`Prefilter::Kind::FirstBytes`) does what the
    # forward DFA's start state does with `StaticByteScan`.
    private def prefilter_of(program : Program) : PrefilterTables?
      literal_set = program.literal_set || return nil
      prefilter = Prefilter.new(literal_set)
      return nil if prefilter.kind.first_bytes?
      list_of_literals = literal_set.list_of_literals
      list_of_bytes = [] of Int32
      list_of_ends = [] of Int32
      list_of_starting_with = Array(UInt64).new(256, 0_u64)
      list_of_words = [] of UInt64
      list_of_word_masks = [] of UInt64
      list_of_literals.each_with_index do |literal, index|
        literal.each { |byte| list_of_bytes << byte.to_i32 }
        list_of_ends << list_of_bytes.size
        list_of_starting_with[literal[0]] |= 1_u64 << index
        word = 0_u64
        literal.each_with_index { |byte, offset| word |= byte.to_u64 << (8 * offset) if offset < 8 }
        list_of_words << (literal.size > 8 ? 0_u64 : word)
        list_of_word_masks << (literal.size > 8 ? 0_u64 : (literal.size == 8 ? UInt64::MAX : (1_u64 << (8 * literal.size)) &- 1))
      end
      PrefilterTables.new(kind: prefilter.kind.value, exact: literal_set.exact?, list_of_literal_bytes: list_of_bytes,
        list_of_literal_ends: list_of_ends, list_of_starting_with: list_of_starting_with, list_of_words: list_of_words,
        list_of_word_masks: list_of_word_masks, needle: prefilter.list_of_needles.first?.try(&.to_i32) || 0,
        needle_offset: prefilter.needle_offset, pair_gap: prefilter.pair_gap, mask_width: prefilter.mask_width,
        list_of_masks: prefilter.masks.to_a, minimum_length: prefilter.minimum_length,
        list_of_pair_tests: words_of(prefilter.list_of_pair_tests), list_of_narrow_tests: words_of(prefilter.list_of_narrow_tests),
        list_of_dense_tests: words_of(prefilter.list_of_dense_tests))
    end

    # *list_of_tests* as `StaticPrefilter::WORDS_PER_TEST` words each.
    private def words_of(list_of_tests : Array(PairTest)) : Array(UInt64)
      list_of_tests.flat_map do |test|
        [test.first_offset.to_u64, test.second_offset.to_u64, test.third_offset.to_u64, test.first_fold, test.first_lanes,
         test.second_fold, test.second_lanes, test.third_fold, test.third_lanes]
      end
    end

    # The most entries `class_targets_of` writes (64 Ki).
    MAX_CLASS_TARGETS = 65_536

    # The target of each `Sparse` state for each byte class, row by state
    # (`program.state_count` rows of `class_count` entries; the state count
    # stands for no target), so the capture passes step a `Sparse` state
    # with one load in place of a binary search; empty when the table
    # would pass `MAX_CLASS_TARGETS` entries. Every byte of a class has the
    # same target: the classes split the bytes at every range bound of the
    # program.
    private def class_targets_of(program : Program, byte_classes : ByteClasses) : Array(Int32)
      class_count = byte_classes.class_count
      return [] of Int32 if program.state_count.to_i64 * class_count > MAX_CLASS_TARGETS
      representatives = Array(Int32).new(class_count, -1)
      256.times do |byte|
        class_index = byte_classes.class_of(byte.to_u8)
        representatives[class_index] = byte if representatives[class_index] < 0
      end
      list_of_targets = Array(Int32).new(program.state_count * class_count, program.state_count)
      program.list_of_states.each_with_index do |state, index|
        next unless state.kind.sparse?
        class_count.times do |class_index|
          target = program.sparse_target(index, state, representatives[class_index].to_u8)
          list_of_targets[index * class_count + class_index] = target if target >= 0
        end
      end
      list_of_targets
    end

    private def flatten(program : Program, byte_classes : ByteClasses) : NfaTables
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
      class_count = byte_classes.class_count
      list_of_class_targets = class_targets_of(program, byte_classes)
      NfaTables.new(list_of_kinds: kinds, list_of_lows: lows, list_of_highs: highs, list_of_next_states: nexts,
        list_of_alternates: alternates, list_of_arguments: arguments, list_of_sparse_lows: sparse_lows,
        list_of_sparse_highs: sparse_highs, list_of_sparse_targets: sparse_targets, list_of_class_targets: list_of_class_targets,
        class_count: class_count, start_state: program.start_state)
    end
  end
end
