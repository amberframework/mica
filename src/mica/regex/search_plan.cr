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
    # The lazily built parts are published through atomics, so a search
    # on another thread that sees one sees it fully built.
    @reverse = Atomic(LazyDFA?).new(nil)
    @one_pass = Atomic(OnePassDFA?).new(nil)
    # Set (after @one_pass) once the one-pass build ran, as its result may
    # be nil.
    @one_pass_built = Atomic(Int32).new(0)
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

    # Takes an idle lease (its caches warm from earlier searches) or makes
    # a new one for *pool*.
    def lease(pool : CachePool) : SearchLease
      lease = @hot_lease.swap(nil) || @mutex.synchronize { @list_of_idle_leases.pop? }
      if lease && lease.pool.same?(pool)
        lease.acquire
        return lease
      end
      SearchLease.new(self, pool)
    end

    # Returns *lease* for a later search to reuse. At most `MAX_IDLE_LEASES`
    # are kept per program.
    # The lease is handed to the pool (idle, evictable) before it is
    # published as the hot lease; one that goes to the idle list instead
    # drops its workspaces first, taken back from the pool meanwhile.
    def give_back(lease : SearchLease) : Nil
      tick = lease.pool.tick
      lease.release_to_pool(tick)
      return if @hot_lease.compare_and_set(nil, lease)[1]
      lease.acquire
      lease.drop_workspaces
      lease.release_to_pool(tick)
      @mutex.synchronize do
        @list_of_idle_leases << lease if @list_of_idle_leases.size < MAX_IDLE_LEASES
      end
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
  # The lease is the `CachePool` member: a search holds it BUSY (one
  # atomic exchange to take it, one store to hand it back), and the pool
  # evicts an idle lease's caches and kept Pike VM workspace together.
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

    # Drops the caches (with their builders' scratch space) and the kept
    # Pike VM workspace, giving their bytes back to the pool. Runs only
    # while the lease is idle and EVICTING; a cache is reserved afresh when
    # the lease is next used.
    protected def evict : Nil
      @forward_cache.try(&.evict)
      @forward_cache = nil
      @reverse_cache.try(&.evict)
      @reverse_cache = nil
      @pike.try(&.release)
    end
  end
end
