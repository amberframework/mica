require "weak_ref"

module Mica::Regex
  # Accounts for the memory of every lazy-DFA cache in the process
  # (roadmap 6.2.4): a cap on the bytes all caches hold together, kept with
  # an atomic counter, and the list of its caches, from which idle ones are
  # reclaimed (oldest first) when the cap is reached.
  #
  # Each cache also has its own ceiling (`max_cache_bytes`, 2 MiB by
  # default); a cache that reaches it clears itself and starts over (see
  # `LazyDFA`). A cache grows in `RESERVATION_BYTES` steps, each reserved
  # here first. When a reservation does not fit, idle caches are evicted,
  # oldest first, and when none is left to evict the search runs on the
  # Pike VM instead, which is slower but stays within its bound.
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

    # The cap on the bytes all caches of this pool hold.
    getter max_bytes : Int64
    # The ceiling of one cache.
    getter max_cache_bytes : Int64
    @reserved = Atomic(Int64).new(0_i64)
    @mutex = Mutex.new
    @list_of_caches = [] of WeakRef(DFACache)

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

    # Returns the bytes reserved now by every cache of the pool.
    def reserved_bytes : Int64
      @reserved.get
    end

    # Reserves *bytes* for a cache. Evicts idle caches (oldest first) when
    # the cap would be passed; returns false when that is not enough.
    def reserve(bytes : Int64) : Bool
      return true if try_reserve(bytes)
      @mutex.synchronize do
        @list_of_caches.reject! { |reference| reference.value.nil? }
        @list_of_caches.each do |reference|
          cache = reference.value
          next unless cache && cache.evict_if_idle
          return true if try_reserve(bytes)
        end
      end
      false
    end

    # Gives back *bytes* a cache had reserved.
    def release(bytes : Int64) : Nil
      @reserved.add(-bytes) if bytes > 0
    end

    # :nodoc:
    # Records a new cache of this pool, so it can be evicted when idle.
    def register(cache : DFACache) : Nil
      @mutex.synchronize { @list_of_caches << WeakRef.new(cache) }
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

  # Replaces the process-wide `CachePool` with one capped at *max_bytes*,
  # each cache at *max_cache_bytes*. Call it once, at the application
  # boundary, before expressions are searched.
  def self.configure_cache_pool(*, max_bytes : Int64,
                                max_cache_bytes : Int64 = CachePool::DEFAULT_MAX_CACHE_BYTES) : CachePool
    CachePool.default = CachePool.new(max_bytes, max_cache_bytes)
  end
end
