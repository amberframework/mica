require "../spec_helper"

# The member list of a `CachePool` is bounded by the expressions alive, not
# by the expressions ever compiled. Every search lease registers a weak
# reference in its pool; `CachePool#register` drops the references of
# collected members once the list reaches twice the size left at its last
# prune (at least `CachePool::PRUNE_FLOOR`). The soak run in
# bench/regex/off_heap/soak.cr checks the resident set over 240,000 rounds.
module CachePoolMembershipSpec
  LIST_OF_PATTERN_TEMPLATES = [
    %q(\b\w+@\w+\.(?:com|org|net)%d\b),
    %q((?i)sherlock|holmes|watson|%d),
    %q(^\s*(\d+)\s*-\s*([A-Z][a-z]+)%d$),
    %q([\p{L}\p{N}]+%d),
    %q((?:a|ab|abc|abcd)+x%d),
    %q("(?:[^"\\]|\\.)*"%d),
    %q(\$\d+|\?%d),
    %q((\w+)\s+\1%d),
  ]

  HAYSTACK = String.build do |text|
    64.times do |index|
      text << "line " << index << " - Sherlock Holmes met user" << index << "@example.com, \"quoted\" $1 ? abcabx café\n"
    end
  end

  # Rounds between forced collections. With 8 expressions a round, at most
  # 8 * COLLECT_EVERY dropped members wait for a collection at any time.
  COLLECT_EVERY = 250

  # The bound: twice the members that can be alive or not yet collected at
  # a prune (8 * COLLECT_EVERY dropped, 8 live), and never under the floor.
  MEMBER_BOUND = Math.max(Mica::Regex::CachePool::PRUNE_FLOOR, 2 * (8 * COLLECT_EVERY + 8))

  {% if flag?(:preview_mt) && flag?(:execution_context) %}
    # Four threads, so registrations and prunes really overlap.
    CONTEXT = Fiber::ExecutionContext::Parallel.new("cache-pool-membership", 4)

    def self.spawn_parallel(&block : -> Nil) : Nil
      CONTEXT.spawn { block.call }
    end
  {% else %}
    def self.spawn_parallel(&block : -> Nil) : Nil
      spawn { block.call }
    end
  {% end %}

  # Compiles, searches and drops the 8 patterns *rounds* times (a new
  # source text each round) on *pool*, and returns the member count after
  # each block of COLLECT_EVERY rounds.
  def self.churn(pool : Mica::Regex::CachePool, rounds : Int32, offset : Int32 = 0) : Array(Int32)
    compile_limits = Mica::Regex::CompileLimits::TRUSTED_PATTERN
    search_limits = Mica::Regex::SearchLimits::TRUSTED_INPUT
    list_of_counts = [] of Int32
    rounds.times do |round|
      LIST_OF_PATTERN_TEMPLATES.each do |template|
        expression = Mica::Regex::Expression.new(template % (offset + round), compile_limits: compile_limits, cache_pool: pool)
        expression.match(HAYSTACK, limits: search_limits)
        expression.scan(HAYSTACK, limits: search_limits)
      end
      if (round + 1) % COLLECT_EVERY == 0
        GC.collect
        list_of_counts << pool.member_count
      end
    end
    list_of_counts
  end
end

describe Mica::Regex::CachePool do
  describe "#register" do
    it "keeps the member list bounded by live expressions over 20,000 compile/search/drop cycles" do
      pool = Mica::Regex::CachePool.new
      list_of_counts = CachePoolMembershipSpec.churn(pool, 2_500)
      # Before the bound, the list held one reference per expression ever
      # compiled: 20,000 here, growing without limit.
      list_of_counts.max.should be <= CachePoolMembershipSpec::MEMBER_BOUND
      # Flat after warm-up: the second half never climbs past the bound or
      # past the first half's peak by more than one prune step.
      half = list_of_counts.size // 2
      list_of_counts[half..].max.should be <= Math.max(list_of_counts[...half].max * 2, Mica::Regex::CachePool::PRUNE_FLOOR)
    end

    it "keeps every live member while it prunes" do
      pool = Mica::Regex::CachePool.new
      compile_limits = Mica::Regex::CompileLimits::TRUSTED_PATTERN
      list_of_live = (0...3_000).map do |index|
        expression = Mica::Regex::Expression.new("a#{index}b+", compile_limits: compile_limits, cache_pool: pool)
        expression.scan("xa#{index}bbb a#{index}b", limits: Mica::Regex::SearchLimits::TRUSTED_INPUT).size.should eq(2)
        expression
      end
      GC.collect
      CachePoolMembershipSpec.churn(pool, 500)
      # 3,000 live leases stay registered (each is still evictable).
      pool.member_count.should be >= 3_000
      list_of_live.size.should eq(3_000)
    end

    it "stays bounded and correct when four fibers compile at once (on four threads under -Dpreview_mt -Dexecution_context)" do
      pool = Mica::Regex::CachePool.new
      done = Channel(Array(Int32)).new(4)
      4.times do |fiber|
        CachePoolMembershipSpec.spawn_parallel do
          done.send(CachePoolMembershipSpec.churn(pool, 750, fiber * 1_000))
        end
      end
      list_of_counts = (0...4).flat_map { done.receive }
      # Four fibers drop up to four times as many members between
      # collections as one does.
      list_of_counts.max.should be <= 4 * CachePoolMembershipSpec::MEMBER_BOUND
      pool.member_count.should be <= 4 * CachePoolMembershipSpec::MEMBER_BOUND
    end
  end
end
