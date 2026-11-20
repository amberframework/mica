module Mica::Regex
  # The states and transitions one `LazyDFA` has built so far, leased to one
  # search at a time (roadmap 6.2.4). Its memory is reserved from a
  # `CachePool` before it is used, it never holds more than the pool's
  # `max_cache_bytes`, and it clears itself when it would.
  #
  # The table holds `stride` entries per state: the next state's entry
  # (`entry_of`), or -1 when that transition has not been built yet. State 0 is the dead
  # state and state 1 the dead state that reports a match first; both stay
  # in every generation of the cache.
  #
  # WARNING: A cache belongs to one search at a time.
  class DFACache
    # The transition table (see the class description).
    getter transition_table : Array(Int32)
    # One byte of `LazyDFA::MARK_*` bits per state.
    getter list_of_marks : Array(UInt8)
    # How many times the cache has been cleared.
    getter clears = 0
    # True once a clear found the searches building a state for fewer than
    # `LazyDFA::MINIMUM_BYTES_PER_STATE` bytes read: the unanchored DFA
    # thrashes on this program, so a searcher prefers
    # `LazyDFA#find_from_each_start` where the program allows it, trying
    # the unanchored DFA again now and then (`retry?`).
    getter? thrashing = false
    # States built and bytes read since the cache was made (see
    # `judge_retry`).
    getter states_built = 0_i64
    getter bytes_read = 0_i64
    @searches_since_thrash = 0
    # Set by an unanchored forward search for the length of its DFA run: a
    # clear that finds the cache thrashing gives up at once, rather than
    # after `LazyDFA::MAX_CLEARS`, when this plan can search from each
    # start instead (`SearchPlan#short_match`, asked only then).
    setter hands_over_to : SearchPlan? = nil
    # The most NFA states one state built so far held, and how many states
    # built held more than `SearchPlan::WIDE_REVERSE_KEY`.
    getter widest_key = 0
    getter wide_states = 0
    @retry_interval = FIRST_RETRY_INTERVAL
    getter dfa : LazyDFA

    # Searches between retries of the unanchored DFA once it thrashes; the
    # interval doubles, up to `LAST_RETRY_INTERVAL`, each time a retry
    # thrashes again.
    FIRST_RETRY_INTERVAL = 256
    LAST_RETRY_INTERVAL  = 1 << 20
    # The fewest states a retry builds before its rate can count as
    # thrashing.
    RETRY_STATES = 32
    @list_of_keys : Array(Array(Int32))
    @state_ids : Hash(Array(Int32), Int32)
    @start_states : Array(Int32)
    @builder : DFABuilder
    @bytes_used = 0_i64
    @reservation : CacheReservation
    @bytes_since_clear = 0_i64
    @states_since_clear = 0
    @generation = 0

    # Returns a new cache for *dfa*, its fixed parts (the builder's scratch
    # space, the start-state table and the two dead states) reserved from
    # *pool* before they are allocated, or nil when the pool cannot supply
    # them or they do not fit under its `max_cache_bytes`.
    #
    # The block returns the scratch space the cache builds states in, and
    # runs only once the reservation succeeds, so a refused cache allocates
    # nothing. A lease's forward and reverse caches share one builder
    # (`SearchLease#builder`), as they never build at the same time. Each
    # cache still reserves the scratch space as its own, so the pool's
    # count stays an upper bound.
    def self.reserve?(dfa : LazyDFA, pool : CachePool, & : -> DFABuilder) : DFACache?
      reservation = CacheReservation.new(pool)
      return nil unless reservation.cover(initial_bytes(dfa), ceiling: pool.max_cache_bytes)
      new(dfa, pool, reservation, yield)
    end

    # The bytes a new cache takes before its first state is built.
    def self.initial_bytes(dfa : LazyDFA) : Int64
      fixed_bytes_of(dfa) + 2 * state_bytes_of(dfa, 1)
    end

    protected def self.fixed_bytes_of(dfa : LazyDFA) : Int64
      DFABuilder::BYTES_PER_STATE.to_i64 * dfa.node_count + 4_i64 * LazyDFA::START_FLAG_COUNT + 256
    end

    protected def self.state_bytes_of(dfa : LazyDFA, key_size : Int32) : Int64
      # Table row, mark, key array (header and elements), hash entry and the
      # key list slot.
      4_i64 * dfa.stride + 1 + 32 + 4_i64 * key_size + 48 + 8
    end

    protected def initialize(@dfa : LazyDFA, @pool : CachePool, @reservation : CacheReservation, @builder : DFABuilder)
      @transition_table = [] of Int32
      @list_of_marks = [] of UInt8
      @list_of_keys = [] of Array(Int32)
      @state_ids = {} of Array(Int32) => Int32
      @start_states = Array(Int32).new(LazyDFA::START_FLAG_COUNT, -1)
      reset_states
    end

    # Bytes the builder's scratch space and the cache's fixed parts take.
    private def fixed_bytes : Int64
      DFACache.fixed_bytes_of(@dfa)
    end

    # Records *count* bytes read by the search, for the thrash rule.
    @[AlwaysInline]
    def note_bytes(count : Int32) : Nil
      @bytes_since_clear += count
      @bytes_read += count
    end

    # Counts a search made from each start because the cache thrashes, and
    # returns true (forgetting the thrashing) once the retry interval has
    # passed, so that search tries the unanchored DFA again; the caller
    # then reports how it went to `judge_retry`.
    def retry? : Bool
      @searches_since_thrash += 1
      return false if @searches_since_thrash < @retry_interval
      @thrashing = false
      @searches_since_thrash = 0
      true
    end

    # Judges a retry of the unanchored DFA that started when `states_built`
    # was *states_before* and `bytes_read` was *bytes_before*: when it
    # built at least `RETRY_STATES` states at fewer than
    # `LazyDFA::MINIMUM_BYTES_PER_STATE` bytes each, the cache thrashes
    # again and the next retry waits twice as long.
    def judge_retry(states_before : Int64, bytes_before : Int64) : Nil
      built = @states_built - states_before
      return if built < RETRY_STATES
      return if @bytes_read - bytes_before >= LazyDFA::MINIMUM_BYTES_PER_STATE.to_i64 * built
      @thrashing = true
      @retry_interval = Math.min(@retry_interval * 2, LAST_RETRY_INTERVAL)
    end

    # Gives every byte the cache reserved back to the pool. Its lease is
    # being evicted and drops the cache (see `SearchLease`), so nothing is
    # rebuilt: the lease reserves a new cache when it is next used.
    def evict : Nil
      @reservation.release_all
    end

    # Returns the start state for *flags*, building it when needed, or
    # `LazyDFA::GAVE_UP`.
    def start_state(dfa : LazyDFA, flags : Int32, meter : SearchMeter) : Int32
      cached = @start_states.unsafe_fetch(flags)
      return cached if cached >= 0
      id = intern(dfa.start_key(flags), meter)
      @start_states[flags] = id if id >= 0
      id
    end

    # Builds the transition of *state* on *symbol*, records it, and returns
    # the next state (or `LazyDFA::GAVE_UP`). Building may clear the cache;
    # the transition is then not recorded, as *state* no longer exists.
    def transition(dfa : LazyDFA, state : Int32, symbol : Int32, meter : SearchMeter) : Int32
      key = dfa.next_key(@list_of_keys[state], symbol, @builder, meter)
      return LazyDFA::GAVE_UP unless key
      generation = @generation
      id = intern(key, meter)
      return id if id < 0
      if generation == @generation
        @transition_table[state * dfa.stride + symbol] = entry_of(id)
        mark_ascii_loop(dfa, state, meter) if id == state
      end
      id
    end

    # Flags the entries of *state*'s own row on the ASCII symbols with
    # `LazyDFA::ASCII_LOOP` once every one of them leads back to *state*,
    # and *state* is neither dead nor a start state, so `LazyDFA#find_end`
    # steps over a run of ASCII bytes there without reading the table (in a
    # match state, as `.*` makes, each byte of the run ends a match).
    # Forward only (the reverse DFA has no ASCII symbols listed).
    #
    # The ASCII symbols the search has not met in *state* yet (the control
    # bytes of English text) are built here when the built ones all lead
    # back: each costs one `LazyDFA#next_key`, charged to *meter*, and is
    # recorded only when it leads back too, so no state is added. At most
    # 128 such keys per state, once per cache generation.
    private def mark_ascii_loop(dfa : LazyDFA, state : Int32, meter : SearchMeter) : Nil
      return if @list_of_marks.unsafe_fetch(state) & (LazyDFA::MARK_DEAD | LazyDFA::MARK_START) != 0
      symbols = dfa.list_of_ascii_symbols
      return if symbols.empty?
      row = state * dfa.stride
      symbols.each do |symbol|
        entry = @transition_table.unsafe_fetch(row + symbol)
        return unless entry < 0 || entry & LazyDFA::ROW_MASK == row
      end
      key = @list_of_keys[state]
      symbols.each do |symbol|
        next unless @transition_table.unsafe_fetch(row + symbol) < 0
        next_key = dfa.next_key(key, symbol, @builder, meter)
        return unless next_key == key
        @transition_table[row + symbol] = entry_of(state)
      end
      entry = entry_of(state) | LazyDFA::ASCII_LOOP
      symbols.each { |symbol| @transition_table[row + symbol] = entry }
    end

    # The table entry for state *id*: its row offset (`id * stride`), with
    # `LazyDFA::SPECIAL` set for a match or dead state and
    # `LazyDFA::START_ENTRY` for a start state.
    @[AlwaysInline]
    def entry_of(id : Int32) : Int32
      offset = id &* @dfa.stride
      marks = @list_of_marks.unsafe_fetch(id)
      offset |= LazyDFA::SPECIAL if marks & (LazyDFA::MARK_MATCH | LazyDFA::MARK_DEAD) != 0
      offset |= LazyDFA::START_ENTRY if marks & LazyDFA::MARK_START != 0
      offset
    end

    private def intern(key : Array(Int32), meter : SearchMeter) : Int32
      if id = @state_ids[key]?
        return id
      end
      cost = state_bytes(key.size)
      if @bytes_used + cost > @pool.max_cache_bytes
        return LazyDFA::GAVE_UP unless clear(meter)
        return LazyDFA::GAVE_UP if @bytes_used + cost > @pool.max_cache_bytes
      end
      return LazyDFA::GAVE_UP unless reserve(@bytes_used + cost)
      @widest_key = key.size if key.size > @widest_key
      @wide_states += 1 if key.size > SearchPlan::WIDE_REVERSE_KEY
      add_state(key.dup, cost)
    end

    private def add_state(key : Array(Int32), cost : Int64) : Int32
      id = @list_of_keys.size
      @list_of_keys << key
      @state_ids[key] = id
      # The dead states lead only to the dead state (entry 0 | SPECIAL).
      @transition_table.concat(id <= LazyDFA::DEAD_MATCH ? @dfa.dead_row : @dfa.unbuilt_row)
      mark = 0_u8
      mark |= LazyDFA::MARK_MATCH if key.unsafe_fetch(0) & LazyDFA::MATCH_BEHIND != 0
      mark |= LazyDFA::MARK_DEAD if id <= LazyDFA::DEAD_MATCH
      mark |= LazyDFA::MARK_START if @dfa.start_like?(key)
      @list_of_marks << mark
      @bytes_used += cost
      @states_since_clear += 1
      @states_built += 1
      id
    end

    private def reserve(bytes : Int64) : Bool
      @reservation.cover(bytes, ceiling: @pool.max_cache_bytes)
    end

    # Clears the cache, charging one operation per state discarded. Returns
    # false when the cache is thrashing (see `LazyDFA`), at the first clear
    # that finds it so when the search can go on from each start
    # (`hands_over_to`).
    private def clear(meter : SearchMeter) : Bool
      meter.charge(@list_of_keys.size, 0)
      @clears += 1
      sparse = @bytes_since_clear < LazyDFA::MINIMUM_BYTES_PER_STATE.to_i64 * @states_since_clear
      @thrashing = true if sparse
      thrashing = sparse && (@clears > LazyDFA::MAX_CLEARS || hands_over?)
      @transition_table.clear
      @list_of_marks.clear
      @list_of_keys.clear
      @state_ids.clear
      reset_states
      !thrashing
    end

    private def hands_over? : Bool
      plan = @hands_over_to
      !plan.nil? && !plan.short_match.nil?
    end

    private def reset_states : Nil
      @generation += 1
      @bytes_used = fixed_bytes
      @bytes_since_clear = 0_i64
      @start_states.fill(-1)
      if @list_of_keys.empty?
        add_state(LazyDFA::DEAD_KEY.dup, state_bytes(1))
        add_state(LazyDFA::DEAD_MATCH_KEY.dup, state_bytes(1))
      end
      @states_since_clear = 0
    end

    private def state_bytes(key_size : Int32) : Int64
      DFACache.state_bytes_of(@dfa, key_size)
    end
  end

  # :nodoc:
  # Scratch space for building DFA states: a stamped set of visited NFA
  # states, the closure stack, the consuming states in priority order, and
  # the key being built with its own stamped set.
  class DFABuilder
    # A state is visited (or a target) in the current build when its stamp
    # equals the current generation, so starting a build is one increment,
    # and each set takes 4 bytes per NFA state.
    @visited_stamps : Array(UInt32)
    @visit_generation = 0_u32
    @target_stamps : Array(UInt32)
    @target_generation = 0_u32
    @stack = [] of Int32
    @outputs = [] of Int32
    @key = [] of Int32

    # The bytes of the two stamp tables per NFA state.
    BYTES_PER_STATE = 8

    def initialize(state_count : Int32)
      @visited_stamps = Array(UInt32).new(state_count, 0_u32)
      @target_stamps = Array(UInt32).new(state_count, 0_u32)
    end

    # The most NFA states (or reverse NFA nodes) a DFA built here may have.
    def node_capacity : Int32
      @visited_stamps.size
    end

    def reset : Nil
      @visit_generation = DFABuilder.next_generation(@visited_stamps, @visit_generation)
      @stack.clear
      @outputs.clear
    end

    # The generation after *generation* for *stamps*, clearing them when
    # the counter wraps around.
    protected def self.next_generation(stamps : Array(UInt32), generation : UInt32) : UInt32
      generation &+= 1
      return generation unless generation == 0
      stamps.fill(0_u32)
      1_u32
    end

    def push(state : Int32) : Nil
      @stack << state
    end

    def pop? : Int32?
      @stack.pop?
    end

    def clear_stack : Nil
      @stack.clear
    end

    # Marks *state* visited; false when it already was.
    def visit(state : Int32) : Bool
      return false if @visited_stamps.unsafe_fetch(state) == @visit_generation
      @visited_stamps.unsafe_put(state, @visit_generation)
      true
    end

    def output(state : Int32) : Nil
      @outputs << state
    end

    def each_output(& : Int32 ->) : Nil
      @outputs.each { |state| yield state }
    end

    def begin_targets(flags : Int32) : Nil
      @key.clear
      @key << flags
      @target_generation = DFABuilder.next_generation(@target_stamps, @target_generation)
    end

    def add_target(state : Int32) : Nil
      return if @target_stamps.unsafe_fetch(state) == @target_generation
      @target_stamps.unsafe_put(state, @target_generation)
      @key << state
    end

    # The key built so far: the flags, then the targets in the order added.
    def targets : Array(Int32)
      @key
    end

    # The key with its targets sorted in place (reverse states have no
    # priority), with no copy.
    def sorted_targets : Array(Int32)
      Slice.new(@key.to_unsafe + 1, @key.size - 1).sort! if @key.size > 2
      @key
    end
  end
end
