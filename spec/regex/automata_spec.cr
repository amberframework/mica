require "../spec_helper"

# Milestone R3's engines one at a time: the lazy DFAs and the paths the
# searcher takes, the one-pass DFA, the literal set and the prefilters, and
# the cache pool. The corpora and the differential compare them with the
# other engines at scale (search_conformance_spec.cr,
# engine_differential_spec.cr).
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def program(source : String, options = Mica::Regex::CompileOptions::None) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, options, compile_limits: TRUSTED).program
end

private def searcher(source : String, haystack : String, engine = Mica::Regex::Engine::Auto,
                     pool = Mica::Regex::CachePool.default) : Mica::Regex::Searcher
  Mica::Regex::Searcher.new(program(source), haystack, LIMITS, nil, engine, pool)
end

private def span(source : String, haystack : String, engine = Mica::Regex::Engine::Auto) : {Array(Int64)?, Mica::Regex::Searcher::Path}
  found = searcher(source, haystack, engine)
  slots = found.find(0, Mica::Regex::MatchOptions::None, true)
  {slots.try(&.to_a), found.last_path}
end

describe "Mica::Regex R3 engines" do
  describe "engine selection" do
    it_satisfies "REGEX-R3-selection", "takes the literal search for a set of literals with no assertion" do
      span("foo|foobar", "xfoobar").should eq({[1_i64, 4_i64], Mica::Regex::Searcher::Path::Literal})
      span("(?:sherlock|holmes)", "mr holmes").should eq({[3_i64, 9_i64], Mica::Regex::Searcher::Path::Literal})
    end

    it_satisfies "REGEX-R3-selection", "takes the lazy DFAs for patterns with assertions, classes and repetitions" do
      span("\\bfoo\\b", "a foo b").should eq({[2_i64, 5_i64], Mica::Regex::Searcher::Path::LazyDFA})
      span("(?m)^b$", "a\nb\n").should eq({[2_i64, 3_i64], Mica::Regex::Searcher::Path::LazyDFA})
      span("[a-z]+X|[a-z]", "abc").should eq({[0_i64, 1_i64], Mica::Regex::Searcher::Path::LazyDFA})
    end

    it_satisfies "REGEX-R3-selection", "leaves \\G, FirstLine and EndAnchored to the Pike VM" do
      span("\\Ga", "aa").should eq({[0_i64, 1_i64], Mica::Regex::Searcher::Path::PikeVM})
      found = Mica::Regex::Searcher.new(program("b", Mica::Regex::CompileOptions::FirstLine), "ab", LIMITS, nil)
      found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([1, 2])
      found.last_path.should eq(Mica::Regex::Searcher::Path::PikeVM)
    end

    it_satisfies "REGEX-R3-dfa", "gives up on a Unicode word assertion next to a non-ASCII byte and still answers" do
      found = searcher("\\bé", "a é")
      found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 4])
      found.dfa_gave_up?.should be_true
      found.last_path.should eq(Mica::Regex::Searcher::Path::PikeVM)
      ascii = searcher("(?aW)\\ba", "é a")
      ascii.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([3, 4])
      ascii.dfa_gave_up?.should be_false
    end

    it_satisfies "REGEX-R3-dfa", "reads $ and \\Z before a final line feed and multiline ^ as PCRE2 does" do
      span("a$", "a\n").should eq({[0_i64, 1_i64], Mica::Regex::Searcher::Path::LazyDFA})
      span("a\\Z", "a\n\n").first.should be_nil
      span("(?m)^", "a\n").first.should eq([0, 0])
      found = searcher("(?m)^", "a\n")
      found.find(1, Mica::Regex::MatchOptions::None, false).should be_nil
    end

    it_satisfies "REGEX-R3-selection", "enforces the work budget and the deadline on the DFA and literal paths" do
      tight = Mica::Regex::SearchLimits.custom(work_ceiling: 1_000_i64)
      haystack = "x" * 10_000 + "abc"
      expect_raises(Mica::Regex::SearchLimitError) do
        Mica::Regex::Expression.new("abc", compile_limits: TRUSTED).match(haystack, limits: tight)
      end
      expect_raises(Mica::Regex::SearchLimitError) do
        Mica::Regex::Expression.new("[a-c]+c", compile_limits: TRUSTED).match(haystack, limits: tight)
      end
      expect_raises(Mica::DeadlineExceededError) do
        Mica::Regex::Expression.new("[a-c]+c", compile_limits: TRUSTED).match(haystack, limits: LIMITS, timeout: -1.seconds)
      end
    end
  end

  describe "the one-pass DFA" do
    it_satisfies "REGEX-R3-one-pass", "is built for one-pass patterns and refused for ambiguous ones" do
      program("(\\d+)-(\\d+)").plan.one_pass.should_not be_nil
      program("^(?<user>[a-z]+)@(?<host>[a-z.]+)$").plan.one_pass.should_not be_nil
      program("(a|ab)(c|bcd)").plan.one_pass.should be_nil
      program("(a*)(a*)").plan.one_pass.should be_nil
    end

    it_satisfies "REGEX-R3-one-pass", "reads the same captures as the backtracker" do
      [
        {"(\\d+)-(\\d+)", "tel 555-1234 x"},
        {"^(?<user>[a-z]+)@(?<host>[a-z.]+)$", "bob@example.com"},
        {"(a)|(b)", "zb"},
        {"x(y)?z", "xz"},
        {"(é+)(\\d)", "éé7"},
      ].each do |source, haystack|
        program(source).plan.one_pass.should_not be_nil
        span(source, haystack).first.should eq(span(source, haystack, Mica::Regex::Engine::TwoPhase).first)
      end
    end
  end

  describe "literal sets and prefilters" do
    it_satisfies "REGEX-R3-accelerators", "extracts prefix literals and knows when they are the whole match" do
      exact = program("foo|bar").literal_set.should_not be_nil
      exact.exact?.should be_true
      exact.list_of_literals.map { |literal| String.new(literal) }.should eq(["foo", "bar"])
      prefix = program("foo\\d+").literal_set.should_not be_nil
      prefix.exact?.should be_false
      program("\\bfoo\\b").literal_set.should_not be_nil
      program("\\bfoo\\b").literal_set.try(&.exact?).should be_false
      program("a*b").literal_set.should be_nil
      program("\\w+").literal_set.should be_nil
      program("(?i)ab").literal_set.try(&.list_of_literals.size).should eq(4)
    end

    it_satisfies "REGEX-R3-accelerators", "chooses the rare-byte, first-byte and packed searchers" do
      program("sherlock\\d").plan.prefilter.try(&.kind).should eq(Mica::Regex::Prefilter::Kind::RareByte)
      program("(?:ab|ac)\\d").plan.prefilter.try(&.kind).should eq(Mica::Regex::Prefilter::Kind::FirstBytes)
      program("(?:ab|bc|cd|de)\\d").plan.prefilter.try(&.kind).should eq(Mica::Regex::Prefilter::Kind::Packed)
    end

    it_satisfies "REGEX-R3-accelerators", "finds the same matches with the accelerators on and off" do
      haystack = "the sherlock holmes stories: Sherlock, SHERLOCK and sherlocked holmes."
      ["sherlock", "(?i)sherlock", "sherlock\\w*", "\\bholmes\\b", "(?:sherlock|holmes)[a-z]*", "s[a-z]+k"].each do |source|
        expression = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
        on = Mica::Regex::Searcher.new(expression.program, haystack, LIMITS, nil, Mica::Regex::Engine::Auto)
        off = Mica::Regex::Searcher.new(expression.program, haystack, LIMITS, nil, Mica::Regex::Engine::TwoPhase)
        offset = 0
        while true
          found = on.find(offset, Mica::Regex::MatchOptions::None, false).try(&.to_a)
          found.should eq(off.find(offset, Mica::Regex::MatchOptions::None, false).try(&.to_a))
          break unless found
          offset = found[1] > found[0] ? found[1].to_i32 : found[0].to_i32 + 1
        end
      end
    end
  end

  describe "the cache pool" do
    it_satisfies "REGEX-R3-cache-pool", "holds every cache within the pool cap and the per-cache ceiling" do
      pool = Mica::Regex::CachePool.new(max_bytes: 512_i64 * 1024, max_cache_bytes: 128_i64 * 1024)
      haystack = String.build { |io| 20_000.times { |index| io << ('a' + index % 7) << ('a' + index % 5) } }
      8.times do |index|
        source = "(?:[a-g]{#{index + 2}}x|[a-c]+y)"
        found = searcher(source, haystack, Mica::Regex::Engine::Auto, pool)
        found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a)
          .should eq(searcher(source, haystack, Mica::Regex::Engine::TwoPhase).find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a))
        pool.reserved_bytes.should be <= pool.max_bytes
        found.finish
      end
    end

    it_satisfies "REGEX-R3-cache-pool", "runs a search on the Pike VM when the pool has no room left" do
      pool = Mica::Regex::CachePool.new(max_bytes: 1_i64, max_cache_bytes: 128_i64 * 1024)
      found = searcher("[a-c]+d", "xxabcabd", Mica::Regex::Engine::Auto, pool)
      found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      found.dfa_gave_up?.should be_true
      pool.reserved_bytes.should eq(0)
    end

    it_satisfies "REGEX-R3-cache-pool", "evicts an idle cache to make room for a busy one" do
      # Each search reserves one step for its forward cache and one for its
      # reverse cache, so the pool holds one search's caches.
      pool = Mica::Regex::CachePool.new(max_bytes: Mica::Regex::CachePool::RESERVATION_BYTES * 2,
        max_cache_bytes: Mica::Regex::CachePool::RESERVATION_BYTES)
      first = searcher("[a-c]+d", "xxabcabd", Mica::Regex::Engine::Auto, pool)
      first.find(0, Mica::Regex::MatchOptions::None, false)
      first.finish
      pool.reserved_bytes.should eq(pool.max_bytes)
      second = searcher("[d-f]+g", "xxdefdeg", Mica::Regex::Engine::Auto, pool)
      second.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      second.dfa_gave_up?.should be_false
      pool.reserved_bytes.should eq(pool.max_bytes)
      third = searcher("[g-i]+j", "xxghighj", Mica::Regex::Engine::Auto, pool)
      third.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      third.dfa_gave_up?.should be_true
    end

    it_satisfies "REGEX-R3-cache-pool", "is configured once at the application boundary" do
      original = Mica::Regex::CachePool.default
      begin
        pool = Mica::Regex.configure_cache_pool(max_bytes: 8_i64 * 1024 * 1024)
        Mica::Regex::CachePool.default.should be(pool)
        pool.max_bytes.should eq(8 * 1024 * 1024)
      ensure
        Mica::Regex::CachePool.default = original
      end
    end
  end
end

describe "Mica::Regex R3 review of the PCRE2 search replay" do
  it_satisfies "REGEX-R2-compiler", "compiles a class of surrogates only (\\p{Cs}) to a state that never matches" do
    expression = Mica::Regex::Expression.new("^\\p{Cs}|b", compile_limits: TRUSTED)
    expression.match("ab", limits: LIMITS).try(&.[0]).should eq("b")
    Mica::Regex::Expression.new("\\p{Cs}", compile_limits: TRUSTED).matches?("a\u{FFFD}", limits: LIMITS).should be_false
  end
end
