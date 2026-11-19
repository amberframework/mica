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
  #    state, for every program without `\G`.
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
    # The fewest bytes and the first bytes of a match (see `StartFilter`).
    getter start_filter : StartFilter
    # The lazily built parts are published through atomics, so a search
    # on another thread that sees one sees it fully built.
    @reverse = Atomic(LazyDFA?).new(nil)
    @one_pass = Atomic(OnePassDFA?).new(nil)
    # Set (after @one_pass) once the one-pass build ran, as its result may
    # be nil.
    @one_pass_built = Atomic(Int32).new(0)
    # Short searches seen before the one-pass DFA was built (see
    # `short_search_one_pass`).
    @short_searches = Atomic(Int32).new(0)
    # 1 once a caller read groups that a search had left to read later.
    @groups_read = Atomic(Int32).new(0)
    @mutex = Mutex.new
    @list_of_idle_leases = [] of SearchLease
    # The most recently returned lease, taken without the mutex.
    @hot_lease = Atomic(SearchLease?).new(nil)

    def initialize(@program : Program)
      @byte_classes = ByteClasses.new(@program)
      @forward = LazyDFA.supports?(@program) ? LazyDFA.new(@program, @byte_classes, false) : nil
      literal_set = @program.literal_set
      @prefilter = literal_set ? Prefilter.new(literal_set) : nil
      @literal_search = !!literal_set.try(&.exact?)
      @anchored_start = SearchPlan.anchored_start?(@program)
      @start_filter = StartFilter.new(@program)
    end

    # True when every path from *program*'s start state reaches a
    # `StartOfText` assertion before it reads a byte or matches.
    def self.anchored_start?(program : Program) : Bool
      states = program.list_of_states
      visited = Set(Int32).new
      list_of_pending = [program.start_state]
      while index = list_of_pending.pop?
        next unless visited.add?(index)
        state = states[index]
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

    # The reverse lazy DFA (built on first use), or nil.
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
      return @one_pass.get if @one_pass_built.get == 1
      return nil if @short_searches.add(1, :relaxed) < ShortSearch::BUILD_AFTER
      one_pass
    end

    # The one-pass DFA when a search has built it already (see `one_pass`),
    # or nil.
    def built_one_pass : OnePassDFA?
      @one_pass_built.get == 1 ? @one_pass.get : nil
    end

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
    # a new cache (the search then runs on the Pike VM).
    def forward_cache(dfa : LazyDFA) : DFACache?
      @forward_cache ||= DFACache.reserve?(dfa, @pool)
    end

    # The reverse cache, as `forward_cache`.
    def reverse_cache(dfa : LazyDFA) : DFACache?
      @reverse_cache ||= DFACache.reserve?(dfa, @pool)
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

    # Drops the caches' states and the kept Pike VM workspace, giving their
    # bytes back to the pool. Runs only while the evictor holds the lease.
    def evict : Nil
      @forward_cache.try(&.evict)
      @reverse_cache.try(&.evict)
      @pike.try(&.release)
    end
  end
end
