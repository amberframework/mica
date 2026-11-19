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

    it_satisfies "REGEX-R3-dfa", "decides Unicode word assertions next to non-ASCII text on the lazy DFAs" do
      found = searcher("\\bé", "a é")
      found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 4])
      found.dfa_gave_up?.should be_false
      found.last_path.should eq(Mica::Regex::Searcher::Path::LazyDFA)
      ascii = searcher("(?aW)\\ba", "é a")
      ascii.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([3, 4])
      ascii.dfa_gave_up?.should be_false
      # Every offset of mixed scripts, word and non-word, one to four bytes
      # per character, against the Pike VM.
      haystack = "Шерлок Холмс, café ß-ǅ x²·𝔘𝔫𝔦 ꙮ_9 ‿a ‐b 中文 áb"
      {"\\b\\w+\\b", "\\B\\w\\B", "\\b.", ".\\b", "\\w+\\b ", "(?:\\b|é)\\w", "\\B.+?\\b"}.each do |source|
        expression = program(source)
        offset = 0
        while offset <= haystack.bytesize
          on = Mica::Regex::Searcher.new(expression, haystack, LIMITS, nil, Mica::Regex::Engine::Auto)
          off = Mica::Regex::Searcher.new(expression, haystack, LIMITS, nil, Mica::Regex::Engine::PikeVM)
          on.find(offset, Mica::Regex::MatchOptions::None, false).try(&.to_a)
            .should eq(off.find(offset, Mica::Regex::MatchOptions::None, false).try(&.to_a))
          on.dfa_gave_up?.should be_false
          on.finish
          off.finish
          offset += 1
          while offset < haystack.bytesize && haystack.byte_at(offset) & 0xC0 == 0x80
            offset += 1
          end
        end
      end
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

    it_satisfies "REGEX-R3-cache-pool", "runs a search on the Pike VM when the pool has no room for a cache" do
      # Room for a Pike VM workspace, not for one cache reservation step.
      pool = Mica::Regex::CachePool.new(max_bytes: 4096_i64, max_cache_bytes: 128_i64 * 1024)
      found = searcher("[a-c]+d", "xxabcabd", Mica::Regex::Engine::Auto, pool)
      found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      found.dfa_gave_up?.should be_true
      found.last_path.should eq(Mica::Regex::Searcher::Path::PikeVM)
      pool.reserved_bytes.should be > 0
      pool.reserved_bytes.should be <= pool.max_bytes
      found.finish
    end

    it_satisfies "REGEX-R3-cache-pool", "raises SearchLimitError when the pool cannot supply a Pike VM workspace" do
      pool = Mica::Regex::CachePool.new(max_bytes: 1_i64, max_cache_bytes: 128_i64 * 1024)
      found = searcher("[a-c]+d", "xxabcabd", Mica::Regex::Engine::Auto, pool)
      error = expect_raises(Mica::Regex::SearchLimitError) do
        found.find(0, Mica::Regex::MatchOptions::None, false)
      end
      error.limit_name.should eq("cache_pool_max_bytes")
      error.limit_value.should eq(1)
      pool.reserved_bytes.should eq(0)
      found.finish
    end

    it_satisfies "REGEX-R3-cache-pool", "evicts the least recently used idle cache to make room for a busy one" do
      # Each search reserves one step for its forward cache and one for its
      # reverse cache; the pool holds two searches' caches and a Pike VM
      # workspace.
      step = Mica::Regex::CachePool::RESERVATION_BYTES
      pool = Mica::Regex::CachePool.new(max_bytes: step * 4 + 8192, max_cache_bytes: step)
      first = program("[a-c]+d")
      second = program("[d-f]+g")
      third = program("[g-i]+j")
      run = ->(target : Mica::Regex::Program, haystack : String) do
        found = Mica::Regex::Searcher.new(target, haystack, LIMITS, nil, Mica::Regex::Engine::Auto, pool)
        span = found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a)
        {span, found}
      end
      run.call(first, "xxabcabd")[1].finish
      run.call(second, "xxdefdeg")[1].finish
      # The first program is used again, so the second is now the least
      # recently used.
      run.call(first, "xxabcabd")[1].finish
      span, busy = run.call(third, "xxghighj")
      span.should eq([2, 8])
      busy.dfa_gave_up?.should be_false
      span, again = run.call(first, "xxabcabd")
      span.should eq([2, 8])
      again.dfa_gave_up?.should be_false
      span, evicted = run.call(second, "xxdefdeg")
      span.should eq([2, 8])
      evicted.dfa_gave_up?.should be_true
      pool.reserved_bytes.should be <= pool.max_bytes
      {busy, again, evicted}.each(&.finish)
    end

    it_satisfies "REGEX-R3-cache-pool", "gives the lease back when a call fails to start" do
      step = Mica::Regex::CachePool::RESERVATION_BYTES
      # Room for one expression's two caches and a Pike VM workspace.
      pool = Mica::Regex::CachePool.new(max_bytes: step * 2 + 8192, max_cache_bytes: step)
      warm = Mica::Regex::Expression.new("[a-c]+d", compile_limits: TRUSTED, cache_pool: pool)
      warm.match("xxabcabd", limits: LIMITS).try(&.[0]).should eq("abcabd")
      invalid = String.new(Bytes[0x61, 0xff, 0x62])
      expect_raises(Mica::EncodingError) { warm.match(invalid, limits: LIMITS) }
      expect_raises(Mica::DeadlineExceededError) { warm.match("xxabcabd", limits: LIMITS, timeout: -1.second) }
      fresh = program("[d-f]+g")
      found = Mica::Regex::Searcher.open(fresh, "xxdefdeg", LIMITS, nil, pool)
      found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      found.last_path.should eq(Mica::Regex::Searcher::Path::LazyDFA)
      found.dfa_gave_up?.should be_false
      found.finish
    end

    it_satisfies "REGEX-R3-cache-pool", "admits exactly as many Pike VM workspaces as the pool holds" do
      # Roadmap 6.2.1 concurrency gate: the Pike VM path is forced, and the
      # pool is sized for exactly 8 workspaces of the program.
      target = program("[a-c]{200}d")
      charge = Mica::Regex::PikeVM.workspace_charge(target, captures: false)
      pool = Mica::Regex::CachePool.new(max_bytes: charge * 8)
      haystack = "x" + "abc" * 70 + "d"
      expected = [(haystack.bytesize - 201).to_i64, haystack.bytesize.to_i64]
      leased = Channel(Nil).new
      barrier = Channel(Nil).new
      done = Channel(Array(Int64)?).new
      8.times do
        spawn do
          holder = Mica::Regex::Searcher.new(target, haystack, LIMITS, nil, Mica::Regex::Engine::PikeVM, pool)
          first = holder.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a)
          leased.send(nil)
          barrier.receive
          second = holder.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a)
          holder.finish
          done.send(first == second ? first : nil)
        end
      end
      8.times { leased.receive }
      pool.reserved_bytes.should eq(charge * 8)
      8.times do
        refused = Mica::Regex::Searcher.new(target, haystack, LIMITS, nil, Mica::Regex::Engine::PikeVM, pool)
        error = expect_raises(Mica::Regex::SearchLimitError) do
          refused.find(0, Mica::Regex::MatchOptions::None, false)
        end
        error.limit_name.should eq("cache_pool_max_bytes")
        refused.finish
        pool.reserved_bytes.should eq(charge * 8)
      end
      8.times { barrier.send(nil) }
      8.times { done.receive.should eq(expected) }
      pool.reserved_bytes.should eq(0)
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
