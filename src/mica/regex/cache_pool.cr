require "weak_ref"

module Mica::Regex
  # Accounts for the memory of every lazy-DFA cache and Pike VM workspace
  # in the process (roadmap 6.2.1 and 6.2.4): a cap on the bytes they hold
  # together, kept with an atomic counter, and the list of its members,
  # from which idle ones are reclaimed, least recently used first, when the
  # cap is reached.
  #
  # **Lazy-DFA caches.** Each cache also has its own ceiling
  # (`max_cache_bytes`, 2 MiB by default); a cache that reaches it clears
  # itself and starts over (see `LazyDFA`). A cache grows in
  # `RESERVATION_BYTES` steps, each reserved here first. When a reservation
  # does not fit, idle members are evicted, and when none is left to evict
  # the search runs on the Pike VM instead, which is slower but stays
  # within its bound.
  #
  # **Pike VM workspaces** are the second lease type. Each is charged its
  # `PikeVM.workspace_charge` (bounded by `CompileLimits#max_pike_bytes`,
  # not by `max_cache_bytes`) before its buffer is allocated. When the pool
  # cannot supply one even after evicting every idle member, the search
  # raises `SearchLimitError` naming `cache_pool_max_bytes`: it never
  # allocates past the cap and never returns a wrong answer.
  #
  # The default pool is the one deliberate piece of global state in
  # Mica::Regex, because a process memory cap cannot be per object. An
  # application sets it once, at its boundary, with
  # `Mica::Regex.configure_cache_pool`. Callers that need isolation build
  # their own pool and pass it to `Expression.new`.
  #
  # ```
  # Mica::Regex.configure_cache_pool(max_bytes: 32_i64 * 1024 * 1024)
  # ```
  class CachePool
    # The default cap of the process-wide pool.
    DEFAULT_MAX_BYTES = 64_i64 * 1024 * 1024
    # The default ceiling of one cache.
    DEFAULT_MAX_CACHE_BYTES = 2_i64 * 1024 * 1024
    # The step in which a cache reserves memory.
    RESERVATION_BYTES = 64_i64 * 1024

    # The cap on the bytes all members of this pool hold.
    getter max_bytes : Int64
    # The ceiling of one cache.
    getter max_cache_bytes : Int64
    @reserved = Atomic(Int64).new(0_i64)
    @mutex = Mutex.new
    @list_of_members = [] of WeakRef(PoolMember)
    # Counts hand-backs, to order idle members by their last use.
    @clock = Atomic(Int64).new(0_i64)

    def initialize(@max_bytes : Int64 = DEFAULT_MAX_BYTES, @max_cache_bytes : Int64 = DEFAULT_MAX_CACHE_BYTES)
      raise ArgumentError.new("max_bytes must be positive") unless @max_bytes > 0
      raise ArgumentError.new("max_cache_bytes must be positive") unless @max_cache_bytes > 0
    end

    # Held in an atomic so a pool configured on one thread is seen whole
    # by every other.
    @@default = Atomic(CachePool).new(CachePool.new)

    # The process-wide pool every expression uses unless it is given one.
    def self.default : CachePool
      @@default.get
    end

    # :nodoc:
    # Replaces the default pool (see `Mica::Regex.configure_cache_pool`).
    def self.default=(pool : CachePool) : CachePool
      @@default.set(pool)
      pool
    end

    # Returns the bytes reserved now by every member of the pool.
    def reserved_bytes : Int64
      @reserved.get
    end

    # Reserves *bytes* for a member. Evicts idle members (least recently
    # used first) when the cap would be passed; returns false when that is
    # not enough.
    def reserve(bytes : Int64) : Bool
      return true if try_reserve(bytes)
      @mutex.synchronize do
        @list_of_members.reject! { |reference| reference.value.nil? }
        list_of_idle_members = [] of PoolMember
        @list_of_members.each do |reference|
          member = reference.value
          list_of_idle_members << member if member && member.idle?
        end
        list_of_idle_members.sort_by!(&.last_used_tick)
        list_of_idle_members.each do |member|
          next unless member.evict_if_idle
          return true if try_reserve(bytes)
        end
      end
      try_reserve(bytes)
    end

    # Reserves *bytes* for *what* (a Pike VM workspace), or raises
    # `SearchLimitError` naming `cache_pool_max_bytes` when the pool cannot
    # supply them.
    def reserve!(bytes : Int64, what : String) : Nil
      return if reserve(bytes)
      raise SearchLimitError.new("cache_pool_max_bytes", @max_bytes,
        "#{what} of #{bytes} bytes, with #{reserved_bytes} bytes of the pool held,", Core::Position.new(0_i64))
    end

    # Gives back *bytes* a member had reserved.
    def release(bytes : Int64) : Nil
      @reserved.add(-bytes) if bytes > 0
    end

    # :nodoc:
    # Records a new member of this pool, so it can be evicted when idle.
    def register(member : PoolMember) : Nil
      @mutex.synchronize { @list_of_members << WeakRef(PoolMember).new(member) }
    end

    # :nodoc:
    # The next tick of the pool clock (see `PoolMember#release_to_pool`).
    def tick : Int64
      @clock.add(1_i64) + 1
    end

    private def try_reserve(bytes : Int64) : Bool
      current = @reserved.get
      loop do
        return false if current + bytes > @max_bytes
        current, swapped = @reserved.compare_and_set(current, current + bytes)
        return true if swapped
      end
    end
  end

  # :nodoc:
  # Memory a `CachePool` accounts for and may reclaim while no search holds
  # it: a `SearchLease`, with its lazy-DFA caches (`DFACache`) and the Pike
  # VM workspace (`PikeVM`) it keeps between calls.
  # A member is BUSY while a search holds it, IDLE once handed back, and
  # EVICTING while the pool drops its memory. An evicted member stays
  # usable: it rebuilds what it needs, reserving again, when next used.
  abstract class PoolMember
    private IDLE     = 0
    private BUSY     = 1
    private EVICTING = 2

    @use = Atomic(Int32).new(BUSY)
    @last_used_tick = Atomic(Int64).new(0_i64)

    # Drops the memory the member holds and gives its bytes back to the
    # pool. Runs only while the member is EVICTING.
    protected abstract def evict : Nil

    # The pool tick of the member's last hand-back.
    def last_used_tick : Int64
      @last_used_tick.get
    end

    # True when no search holds the member.
    def idle? : Bool
      @use.get == IDLE
    end

    # Takes the member for a search, waiting while the pool evicts it.
    def acquire : Nil
      until @use.compare_and_set(IDLE, BUSY)[1]
        Fiber.yield
      end
    end

    # Hands the member back at pool tick *tick*; the pool may now evict
    # it.
    def release_to_pool(tick : Int64) : Nil
      @last_used_tick.set(tick)
      @use.set(IDLE)
    end

    # Evicts the member when no search holds it. Returns true when it did.
    def evict_if_idle : Bool
      return false unless @use.compare_and_set(IDLE, EVICTING)[1]
      evict
      @use.set(IDLE)
      true
    end
  end

  # :nodoc:
  # The bytes one `PoolMember` has reserved from its pool. It is a separate
  # object, referring to nothing but the pool, so its finalizer can give
  # the bytes back when the member is collected without a finalization
  # cycle (the member itself is reachable from its own program).
  class CacheReservation
    getter bytes = 0_i64
    getter pool : CachePool

    def initialize(@pool : CachePool)
    end

    # Reserves enough to hold *total* bytes in all, in steps of at least
    # *step* bytes (`CachePool::RESERVATION_BYTES` for a lazy-DFA cache,
    # 1 for a Pike VM workspace, which reserves its exact charge); false
    # when the pool refuses.
    def cover(total : Int64, step minimum_step : Int64 = CachePool::RESERVATION_BYTES) : Bool
      return true if total <= @bytes
      step = Math.max(minimum_step, total - @bytes)
      return false unless @pool.reserve(step)
      @bytes += step
      true
    end

    def release_all : Nil
      @pool.release(@bytes)
      @bytes = 0_i64
    end

    def finalize
      @pool.release(@bytes)
    end
  end

  # Replaces the process-wide `CachePool` with one capped at *max_bytes*,
  # each cache at *max_cache_bytes*. Call it once, at the application
  # boundary, before expressions are searched.
  def self.configure_cache_pool(*, max_bytes : Int64,
                                max_cache_bytes : Int64 = CachePool::DEFAULT_MAX_CACHE_BYTES) : CachePool
    CachePool.default = CachePool.new(max_bytes, max_cache_bytes)
  end
end
