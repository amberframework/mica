module Mica::Regex
  # The engines a `Program` can run besides the Pike VM and the bounded
  # backtracker, chosen and built the first time the program is searched
  # (so compiling stays as cheap as R2 made it), and the caches its
  # searches lease.
  #
  # **Engine selection**, fastest correct path first:
  #
  # 1. **Literal search** when the pattern is a finite set of literals with
  #    no assertion (`LiteralSet#exact?`): the prefilter finds the match.
  # 2. **Lazy DFA**, forward for the end and reverse for the start, with
  #    the prefilter skipping ahead while the forward DFA is in its start
  #    state, for every program without `\G`. The reverse DFA is widened
  #    to read classes backward (`widen_reverse`) once its states grow
  #    wide. A program whose matches are short (`short_match`) finds the
  #    start with the forward DFA run anchored from each start while the
  #    reverse cache thrashes, and is searched that way while the forward
  #    cache thrashes.
  # 3. **Pike VM** (span layout) when neither applies, under
  #    `CompileOptions::FirstLine` or `EndAnchored`, and whenever a lazy DFA
  #    gives up (cache thrash, a full `CachePool`, a Unicode word assertion
  #    next to a non-ASCII byte).
  #
  # Captures, when asked for, come from the **one-pass DFA** when the
  # pattern is one-pass, else the bounded backtracker when the span fits
  # it, else the Pike VM.
  #
  # A plan is shared by every search of its program; its lazily built
  # parts are built under a mutex.
  class SearchPlan
    getter program : Program
    getter byte_classes : ByteClasses
    # The forward lazy DFA, or nil when the program needs the Pike VM.
    getter forward : LazyDFA?
    # The prefilter, or nil.
    getter prefilter : Prefilter?
    # True when the prefilter alone finds matches (see `LiteralSet#exact?`).
    getter? literal_search : Bool
    # True when every match starts at the start of the text (each path from
    # the start state passes `\A` before it reads a byte): a search is
    # then anchored at its offset, and the reverse DFA is not needed.
    getter? anchored_start : Bool
    # True when the empty string matches at every offset (a path from the
    # start state reaches a match through no byte and no assertion, as in
    # `.*` or `(a*)`): the leftmost match then starts at the search's
    # offset (see `anchored_at_offset?`).
    getter? empty_match_everywhere : Bool
    # The lazily built parts are published through atomics, so a search
    # on another thread that sees one sees it fully built.
    @reverse = Atomic(LazyDFA?).new(nil)
    @reverse_with_reversed_classes = Atomic(LazyDFA?).new(nil)
    # Set once `widen_reverse` found the widened DFA too large.
    @widen_refused = Atomic(Int32).new(0)
    # Match starts found by the backtracker (see `backtrack_start?`).
    @backtracked_starts : Atomic(Int32)
    @one_pass = Atomic(OnePassDFA?).new(nil)
    # Set (after @one_pass) once the one-pass build ran, as its result may
    # be nil.
    @one_pass_built = Atomic(Int32).new(0)
    # Short searches seen before the one-pass DFA was built (see
    # `short_search_one_pass`), counting from the first searches the
    # program ran without a plan (`FirstSearch`): a program searched that
    # often is searched again.
    @short_searches : Atomic(Int32)
    # Unanchored short searches that ran out of tries (see `ShortSearch`).
    @short_declines = Atomic(Int32).new(0)
    # Candidate searches that ran out of tries (see `CandidateSearch`).
    @candidate_declines = Atomic(Int32).new(0)
    # Candidate searches that found their match (counted without a
    # read-modify-write: a lost count only delays the verdict).
    @candidate_matches = Atomic(Int32).new(0)
    # Searches that skipped the candidate search (see
    # `candidate_searches_pay?`).
    @candidate_skips = Atomic(Int32).new(0)
    # The last haystack a short search found to be valid UTF-8.
    @short_validated = Atomic(String?).new(nil)
    # 1 once a caller read groups that a search had left to read later.
    @groups_read = Atomic(Int32).new(0)
    @fixed_match_bytes = Atomic(Int32).new(FIXED_LENGTH_UNKNOWN)
    @short_match = Atomic(ShortMatch?).new(nil)
    @short_match_built = Atomic(Int32).new(0)
    @start_filter = Atomic(StartFilter?).new(nil)
    @mutex = Mutex.new
    @list_of_idle_leases = [] of SearchLease
    # The most recently returned lease, taken without the mutex.
    @hot_lease = Atomic(SearchLease?).new(nil)

    def initialize(@program : Program)
      # A program with class runs (`Program::ClassRun`) writes its states
      # out here, once, so the plan's engines read each state from one
      # array (`Program#state_at`); its first searches built nothing.
      @program.list_of_states
      @short_searches = Atomic(Int32).new(@program.first_search_count)
      @backtracked_starts = Atomic(Int32).new(@program.first_searches_ended? ? FirstSearch::SEARCHES : 0)
      @byte_classes = ByteClasses.new(@program)
      @forward = LazyDFA.supports?(@program) ? LazyDFA.new(@program, @byte_classes, false) : nil
      literal_set = @program.literal_set
      @prefilter = literal_set ? Prefilter.new(literal_set) : nil
      @literal_search = !!literal_set.try(&.exact?)
      @anchored_start = SearchPlan.anchored_start?(@program)
      @empty_match_everywhere = SearchPlan.empty_match_everywhere?(@program)
    end

    # True when a search from an offset may run anchored there, as the
    # leftmost match starts there if anywhere: every match starts at the
    # start of the text (`anchored_start?`), or the empty string matches
    # at every offset (`empty_match_everywhere?`) and the match need not
    # end at the end of the text (*end_anchored* false; under it the
    # empty match at the offset does not count).
    def anchored_at_offset?(end_anchored : Bool) : Bool
      @anchored_start || (@empty_match_everywhere && !end_anchored)
    end

    # The fewest bytes and the first bytes of a match (see `StartFilter`),
    # made on first use: only short searches read it, so a plan whose
    # haystacks are long never pays for it.
    @[AlwaysInline]
    def start_filter : StartFilter
      @start_filter.get(:acquire) || build_start_filter
    end

    private def build_start_filter : StartFilter
      @mutex.synchronize do
        built = @start_filter.get
        return built if built
        built = StartFilter.new(@program)
        @start_filter.set(built)
        built
      end
    end

    # True when every path from *program*'s start state reaches a
    # `StartOfText` assertion before it reads a byte or matches.
    def self.anchored_start?(program : Program) : Bool
      visited = Set(Int32).new
      list_of_pending = [program.start_state]
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = program.state_at(index)
        case state.kind
        when .split?
          list_of_pending << state.next_state << state.alternate
        when .save?
          list_of_pending << state.next_state
        when .look?
          next if Program::LookKind.new(state.argument).start_of_text?
          list_of_pending << state.next_state
        when .fail?
          next
        else
          return false
        end
      end
      true
    end

    # True when a path from *program*'s start state reaches a match state
    # through splits and group saves alone: no byte, and no assertion.
    def self.empty_match_everywhere?(program : Program) : Bool
      visited = Set(Int32).new
      list_of_pending = [program.start_state]
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = program.state_at(index)
        case state.kind
        when .match? then return true
        when .split? then list_of_pending << state.next_state << state.alternate
        when .save?  then list_of_pending << state.next_state
        end
      end
      false
    end

    # The reverse lazy DFA (built on first use; replaced once by
    # `widen_reverse`), or nil.
    def reverse : LazyDFA?
      return nil unless @forward
      if built = @reverse.get
        return built
      end
      @mutex.synchronize do
        built = @reverse.get
        return built if built
        built = LazyDFA.new(@program, @byte_classes, true)
        @reverse.set(built)
        built
      end
    end

    # A reverse DFA state holding more NFA states than this is wide; a
    # reverse cache that has built `WIDE_STATES_TO_WIDEN` wide states makes
    # `widen_reverse` worth its one-time cost (a single short search does
    # not).
    WIDE_REVERSE_KEY     = 256
    WIDE_STATES_TO_WIDEN =  16

    # Replaces the reverse DFA with one that reads each class backward
    # through its `ReversedClass`, once: a search whose reverse cache has
    # built `WIDE_STATES_TO_WIDEN` states wider than `WIDE_REVERSE_KEY` NFA
    # states calls it (large Unicode classes next to non-ASCII text).
    # Reversing a class costs milliseconds the first time in a process, so
    # only programs that need it pay.
    #
    # The widened DFA reads more NFA nodes, so its cache's fixed part is
    # larger; when that part would take more than half of
    # *max_cache_bytes* (`\p{L}{256}` repeats one class 256 times), the
    # plan keeps its reverse DFA and does not try again.
    def widen_reverse(max_cache_bytes : Int64) : Nil
      return if @widen_refused.get == 1
      current = @reverse.get
      return if current && current.with_reversed_classes?
      return if @program.list_of_class_blocks.empty?
      # The widened DFA has at least the program's nodes; only when those fit
      # are the reversed classes counted.
      scratch_per_node = DFABuilder::BYTES_PER_STATE.to_i64 * 2
      node_limit = max_cache_bytes // scratch_per_node
      if @program.state_count > node_limit || ReverseNFA.widened_node_count(@program, node_limit) > node_limit
        @widen_refused.set(1)
        return
      end
      widened = reverse_with_reversed_classes || return
      @mutex.synchronize { @reverse.set(widened) }
    end

    # The reverse DFA that reads each class backward through its
    # `ReversedClass` (built on first use), or nil when the program needs
    # the Pike VM. `widen_reverse` makes it the reverse DFA;
    # `Engine::ReversedClasses` uses it from the start.
    def reverse_with_reversed_classes : LazyDFA?
      return nil unless @forward
      if built = @reverse_with_reversed_classes.get
        return built
      end
      @mutex.synchronize do
        built = @reverse_with_reversed_classes.get
        return built if built
        built = LazyDFA.new(@program, @byte_classes, true, with_reversed_classes: true)
        @reverse_with_reversed_classes.set(built)
        built
      end
    end

    # True while match starts should come from the bounded backtracker
    # rather than the reverse DFA (see `Searcher#backtracked_start`): the
    # reverse DFA is not built yet and the plan has found fewer than
    # `FirstSearch::SEARCHES` starts this way, so a program searched once
    # or twice never builds its reverse NFA. Counts the start.
    def backtrack_start? : Bool
      return false unless @reverse.get.nil?
      return false if @backtracked_starts.get(:relaxed) >= FirstSearch::SEARCHES
      @backtracked_starts.add(1, :relaxed) < FirstSearch::SEARCHES
    end

    # The one-pass DFA (built on first use), or nil when the program is not
    # one-pass.
    def one_pass : OnePassDFA?
      return @one_pass.get if @one_pass_built.get == 1
      @mutex.synchronize do
        if @one_pass_built.get == 0
          @one_pass.set(OnePassDFA.build(@program, @byte_classes))
          @one_pass_built.set(1)
        end
      end
      @one_pass.get
    end

    # True when a single search should leave the groups of its match to be
    # read on first use (`GroupReader`): the program has groups and the
    # one-pass DFA cannot read them, so reading them means the bounded
    # backtracker or the Pike VM. When the one-pass DFA can, its O(L) pass
    # costs less than a later call would, and the groups are read with the
    # match.
    #
    # Until a search has built the one-pass DFA (the first capture pass
    # does), this is false, so a search that never matches never pays for
    # building it. Once a caller has read the groups of a match found
    # without them (`note_groups_read`), it is false for good: this
    # program's callers read groups, and reading them later costs more
    # than reading them with the match.
    def defers_groups? : Bool
      @program.slot_count > 2 && @one_pass_built.get == 1 && @one_pass.get.nil? &&
        @groups_read.get(:relaxed) == 0
    end

    # True while unanchored short searches of this program usually find
    # their match within `ShortSearch::MAX_TRIES` tries.
    def short_tries_pay? : Bool
      @short_declines.get(:relaxed) < ShortSearch::MAX_DECLINES
    end

    def note_short_decline : Nil
      @short_declines.add(1, :relaxed)
    end

    # True while this program's candidate searches usually find their
    # match within `CandidateSearch::MAX_TRIES` tries: fewer than
    # `CandidateSearch::MAX_DECLINES` declines, or at least
    # `CandidateSearch::MATCHES_PER_DECLINE` matches for each.
    #
    # A program that fails this still tries one search in
    # `CandidateSearch::RETRY_INTERVAL`, so matches found later (the text
    # changed, or the declines came early) can bring it back.
    def candidate_searches_pay? : Bool
      declines = @candidate_declines.get(:relaxed)
      return true if declines < CandidateSearch::MAX_DECLINES
      return true if @candidate_matches.get(:relaxed) >= declines.to_i64 * CandidateSearch::MATCHES_PER_DECLINE
      skipped = @candidate_skips.get(:relaxed) &+ 1
      @candidate_skips.set(skipped, :relaxed)
      skipped % CandidateSearch::RETRY_INTERVAL == 0
    end

    def note_candidate_match : Nil
      matches = @candidate_matches.get(:relaxed)
      @candidate_matches.set(matches &+ 1, :relaxed) if matches < Int32::MAX
    end

    def note_candidate_decline : Nil
      @candidate_declines.add(1, :relaxed)
    end

    # True when *haystack* is the very `String` a short search validated
    # last (see `ShortSearch`).
    def short_validated?(haystack : String) : Bool
      @short_validated.get(:relaxed).same?(haystack)
    end

    def remember_short_validated(haystack : String) : Nil
      @short_validated.set(haystack, :relaxed)
    end

    # Records that a caller read the groups of a match found without them
    # (see `defers_groups?`).
    def note_groups_read : Nil
      @groups_read.set(1, :relaxed)
    end

    # The one-pass DFA for `ShortSearch#run`: built (see `one_pass`) once
    # the program has had `ShortSearch::BUILD_AFTER` short searches, or as
    # soon as another search built it; nil before, or when the program is
    # not one-pass.
    def short_search_one_pass : OnePassDFA?
      return @one_pass.get(:relaxed) if @one_pass_built.get(:acquire) == 1
      return nil if @short_searches.add(1, :relaxed) < ShortSearch::BUILD_AFTER
      one_pass
    end

    # True once a search has built the one-pass DFA (see `one_pass`),
    # whether or not the program is one-pass.
    def one_pass_built? : Bool
      @one_pass_built.get == 1
    end

    # The one-pass DFA when a search has built it already (see `one_pass`),
    # or nil.
    def built_one_pass : OnePassDFA?
      @one_pass_built.get(:acquire) == 1 ? @one_pass.get(:relaxed) : nil
    end

    # The analysis of short matches (made on first use), or nil when a
    # match can be long (see `ShortMatch`).
    def short_match : ShortMatch?
      return @short_match.get if @short_match_built.get == 1
      @mutex.synchronize do
        if @short_match_built.get == 0
          @short_match.set(ShortMatch.analyze(@program))
          @short_match_built.set(1)
        end
      end
      @short_match.get
    end

    # The most states a program may have for `fixed_match_bytes` to
    # analyze it (one O(m) pass, made once).
    FIXED_LENGTH_STATES = 2_048

    # The length in bytes every match has, or -1 when matches can differ
    # in length (or the program has more than `FIXED_LENGTH_STATES`
    # states): the longest match (`ShortMatch.longest_match`) is as long as
    # the shortest (`StartFilter#minimum_bytes`). A match that ends at a
    # known position then starts this many bytes before it. Worked out on
    # first use and kept.
    def fixed_match_bytes : Int32
      length = @fixed_match_bytes.get(:relaxed)
      return length unless length == FIXED_LENGTH_UNKNOWN
      length = -1
      if @program.state_count <= FIXED_LENGTH_STATES && (longest = ShortMatch.longest_match(@program))
        length = longest if longest == start_filter.minimum_bytes
      end
      @fixed_match_bytes.set(length, :relaxed)
      length
    end

    private FIXED_LENGTH_UNKNOWN = -2

    # Takes an idle lease (its caches warm from earlier searches) or makes
    # a new one for *pool*. Taking the lease out of the hot slot or the idle
    # list is what makes the caller its only holder (see `PoolMember`).
    def lease(pool : CachePool) : SearchLease
      lease = @hot_lease.swap(nil, :acquire) || @mutex.synchronize { @list_of_idle_leases.pop? }
      return lease if lease && lease.pool.same?(pool)
      SearchLease.new(self, pool)
    end

    # Returns *lease* for a later search to reuse. At most `MAX_IDLE_LEASES`
    # are kept per program.
    # The hot slot takes the lease as it is, workspaces and all; one that
    # goes to the idle list instead drops its workspaces first.
    def give_back(lease : SearchLease) : Nil
      lease.note_use(lease.pool.tick)
      return if @hot_lease.compare_and_set(nil, lease, :release, :relaxed)[1]
      lease.drop_workspaces
      kept = @mutex.synchronize do
        @list_of_idle_leases << lease if @list_of_idle_leases.size < MAX_IDLE_LEASES
      end
      # A lease no slot keeps can no longer be evicted, so it gives its
      # bytes back now.
      lease.evict unless kept
    end

    # :nodoc:
    # Evicts *lease* when it is idle here: taken out of the hot slot (and
    # put back after), or evicted where it waits in the idle list, under
    # the mutex every taker of the list holds. Returns false when a search
    # holds it.
    def evict_if_idle(lease : SearchLease) : Bool
      if @hot_lease.compare_and_set(lease, nil, :acquire, :relaxed)[1]
        lease.evict
        give_back(lease)
        return true
      end
      @mutex.synchronize do
        return false unless @list_of_idle_leases.any?(&.same?(lease))
        lease.evict
      end
      true
    end

    # Idle leases kept per program.
    MAX_IDLE_LEASES = 8
  end

  # :nodoc:
  # The caches one search call uses: the forward and reverse lazy-DFA
  # caches (made on first use), the Pike VM and backtracker workspaces of
  # the last call (kept only while the lease is the program's hot lease,
  # so a program retains at most one set), and the last haystack the lease
  # validated.
  #
  # The lease is the `CachePool` member: a search holds it from taking it
  # out of the plan's hot slot (one atomic exchange) to putting it back
  # (one compare-and-set), and the pool evicts an idle lease's caches and
  # kept Pike VM workspace together.
  class SearchLease < PoolMember
    getter pool : CachePool
    @forward_cache : DFACache?
    @reverse_cache : DFACache?
    @builder : DFABuilder?
    # The last haystack validated, held strongly: while it is held its
    # address cannot be reused by another string, so identity proves it is
    # the same (immutable) string. A searcher parked in the lease holds its
    # last haystack too, so this retains nothing more.
    @validated : String?
    @pike : PikeVM?
    @backtracker : BoundedBacktracker?
    @searcher : Searcher?

    # Takes the searcher a finished call parked here, if any.
    def take_searcher : Searcher?
      searcher = @searcher
      @searcher = nil
      searcher
    end

    # Takes the kept Pike VM workspace, if any.
    def take_pike : PikeVM?
      pike = @pike
      @pike = nil
      pike
    end

    # Takes the kept backtracker, if any.
    def take_backtracker : BoundedBacktracker?
      backtracker = @backtracker
      @backtracker = nil
      backtracker
    end

    # Keeps the workspaces (and the searcher) of the call that is ending,
    # for the next call.
    def keep(pike : PikeVM?, backtracker : BoundedBacktracker?, searcher : Searcher?) : Nil
      @pike = pike
      @backtracker = backtracker
      @searcher = searcher
    end

    # Drops the kept workspaces (a lease that goes to the idle list). The
    # caller holds the lease, so the pool cannot evict it meanwhile.
    def drop_workspaces : Nil
      if pike = @pike
        pike.release
      end
      @pike = nil
      @backtracker = nil
      @searcher = nil
    end

    def initialize(@plan : SearchPlan, @pool : CachePool)
      @pool.register(self)
    end

    # The forward cache, made on first use; nil when the pool cannot supply
    # a new cache (the search then runs on the Pike VM). The cache's bytes,
    # the builder's scratch space among them, are reserved before the
    # builder is made, so a refused cache leaves no builder behind.
    def forward_cache(dfa : LazyDFA) : DFACache?
      @forward_cache ||= reserve_cache(dfa)
    end

    # The reverse cache, as `forward_cache`.
    # A cache made for an earlier reverse DFA (see
    # `SearchPlan#widen_reverse`) is evicted and replaced.
    def reverse_cache(dfa : LazyDFA) : DFACache?
      cache = @reverse_cache
      if cache && !cache.dfa.same?(dfa)
        cache.evict
        cache = @reverse_cache = nil
      end
      cache || (@reverse_cache = reserve_cache(dfa))
    end

    # Reserves a new cache for *dfa* from the pool, then makes the builder
    # it shares (`builder`). When the pool refuses, no builder is made, and
    # one no remaining cache holds is dropped, so the lease keeps no
    # scratch space the pool does not account for.
    private def reserve_cache(dfa : LazyDFA) : DFACache?
      cache = DFACache.reserve?(dfa, @pool) { builder(dfa) }
      @builder = nil unless cache || @forward_cache || @reverse_cache
      cache
    end

    # The scratch space the caches build their states in: a search builds
    # in one cache at a time, so the forward and the reverse cache share
    # one, sized for the DFA with the most nodes (a reverse DFA that reads
    # classes backward has more nodes than the program has states). A
    # larger DFA gets a new builder; a cache made earlier keeps its own.
    private def builder(dfa : LazyDFA) : DFABuilder
      builder = @builder
      return builder if builder && builder.node_capacity >= dfa.node_count
      @builder = DFABuilder.new(dfa.node_count)
    end

    # True when *haystack* is the very `String` this lease validated last:
    # strings are immutable, so it is still valid UTF-8.
    def validated?(haystack : String) : Bool
      @validated.same?(haystack)
    end

    def remember_validated(haystack : String) : Nil
      @validated = haystack
    end

    def evict_if_idle : Bool
      @plan.evict_if_idle(self)
    end

    # Drops the caches (with their shared builder's scratch space) and the
    # kept Pike VM workspace, giving their bytes back to the pool. Runs only
    # while the evictor holds the lease; a cache is reserved afresh when the
    # lease is next used.
    def evict : Nil
      @forward_cache.try(&.evict)
      @forward_cache = nil
      @reverse_cache.try(&.evict)
      @reverse_cache = nil
      @builder = nil
      @pike.try(&.release)
    end
  end
end
