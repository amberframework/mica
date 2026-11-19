require "weak_ref"

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
        lease.wake
        return lease
      end
      SearchLease.new(self, pool)
    end

    # Returns *lease* for a later search to reuse. At most `MAX_IDLE_LEASES`
    # are kept per program.
    def give_back(lease : SearchLease) : Nil
      lease.sleep
      return if @hot_lease.compare_and_set(nil, lease)[1]
      lease.drop_workspaces
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
  class SearchLease
    getter pool : CachePool
    @forward_cache : DFACache?
    @reverse_cache : DFACache?
    @validated : WeakRef(String)?
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
    # Pike VM workspace is taken back from the pool first, so the pool
    # cannot evict it while it is released.
    def drop_workspaces : Nil
      if pike = @pike
        pike.acquire
        pike.release
      end
      @pike = nil
      @backtracker = nil
      @searcher = nil
    end

    def initialize(@plan : SearchPlan, @pool : CachePool)
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
      validated = @validated
      return false unless validated
      validated.value.same?(haystack)
    end

    def remember_validated(haystack : String) : Nil
      @validated = WeakRef.new(haystack)
    end

    # Takes the caches and the kept Pike VM workspace back from the pool
    # for a search.
    def wake : Nil
      @forward_cache.try(&.acquire)
      @reverse_cache.try(&.acquire)
      @pike.try(&.acquire)
    end

    # Hands the caches and the kept Pike VM workspace to the pool while the
    # lease is idle (evictable).
    def sleep : Nil
      tick = @pool.tick
      @forward_cache.try(&.release_to_pool(tick))
      @reverse_cache.try(&.release_to_pool(tick))
      @pike.try(&.release_to_pool(tick))
    end
  end
end
