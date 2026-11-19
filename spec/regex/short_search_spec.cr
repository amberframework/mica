require "../spec_helper"

# The per-call path of a short search: groups read on first use, the hot
# lease taken and returned with one atomic operation each, and a call that
# allocates nothing when its pattern has no groups.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def expression(source : String, pool = Mica::Regex::CachePool.default) : Mica::Regex::Expression
  Mica::Regex::Expression.new(source, compile_limits: TRUSTED, cache_pool: pool)
end

# The bytes the GC handed out while the block ran.
private def bytes_allocated(&) : Int64
  before = GC.stats.total_bytes
  yield
  (GC.stats.total_bytes - before).to_i64
end

describe "Mica::Regex short searches" do
  describe "groups read on first use" do
    it_satisfies "REGEX-R3-short-search", "finds the match without its groups when only the backtracker or the Pike VM can read them" do
      email = expression("\\A[\\w+\\-.]+@[a-z\\d\\-]+(\\.[a-z\\d\\-]+)*\\.[a-z]+\\z")
      # The first match builds the one-pass DFA and finds it cannot be had.
      email.program.plan.defers_groups?.should be_false
      email.match("ann@example.org", limits: LIMITS).try(&.[1]?).should be_nil
      email.program.plan.defers_groups?.should be_true
      match = email.match("john.smith@example.co.uk", limits: LIMITS).should_not be_nil
      match[0].should eq("john.smith@example.co.uk")
      match[1].should eq(".co")
      match.byte_begin(1).should eq(18)
      match.to_a.should eq(["john.smith@example.co.uk", ".co"])
    end

    it_satisfies "REGEX-R3-short-search", "reads the groups with the match when the one-pass DFA can" do
      placeholder = expression("\\{\\{([^}]+)\\}\\}")
      placeholder.program.plan.defers_groups?.should be_false
      placeholder.match("x {{name}} y", limits: LIMITS).try(&.[1]).should eq("name")
    end

    it_satisfies "REGEX-R3-short-search", "reads the groups of a match from where its search started" do
      # \b depends on the byte before the search's offset, and the group
      # that took part depends on the alternation's priority.
      pattern = expression("\\b(a|ab)(b)?\\b|(ab)")
      pattern.match("ab", limits: LIMITS)
      pattern.program.plan.defers_groups?.should be_true
      match = pattern.match_at_byte_index("zab ab", 1, limits: LIMITS).should_not be_nil
      {match.byte_begin(0), match.byte_end(0)}.should eq({1, 3})
      match[1]?.should be_nil
      match[3].should eq("ab")
      later = pattern.match_at_byte_index("zab ab", 4, limits: LIMITS).should_not be_nil
      later.to_a.should eq(["ab", "a", "b", nil])
    end

    it_satisfies "REGEX-R3-short-search", "shares the groups between copies and compares them" do
      pattern = expression("(a|ab)(c|bcd)(d*)")
      first = pattern.match("abcd", limits: LIMITS).should_not be_nil
      copy = first
      first[2].should eq("bcd")
      copy[2].should eq("bcd")
      second = pattern.match("abcd", limits: LIMITS).should_not be_nil
      (first == second).should be_true
      first.hash.should eq(second.hash)
      third = pattern.match("abcdabc", 1, limits: LIMITS)
      (first == third).should be_false
    end

    it_satisfies "REGEX-R3-short-search", "agrees with the groups the search reads at once on every engine path" do
      list_of_cases = {
        {"(a+)(b+)?(c)", "xaaabbc aac"},
        {"(\\w+)@(\\w+)(\\.\\w+)*", "mail ann@example.co.uk now"},
        {"(?i)(x|xy)(y?z)", "XYZ"},
        {"(?m)^(\\d+)(?:,(\\d+))*$", "1,2,3\n45"},
      }
      list_of_cases.each do |source, haystack|
        pattern = expression(source)
        lazy = pattern.match(haystack, limits: LIMITS).should_not be_nil
        eager = nil
        pattern.each_match(haystack, limits: LIMITS) { |match| eager ||= match }
        eager.should_not be_nil
        lazy.to_a.should eq(eager.try(&.to_a))
      end
    end

    it_satisfies "REGEX-R3-short-search", "reads deferred groups under the limits of the call that found the match" do
      pattern = expression("(a|ab)(c|bcd)(d*)")
      tight = Mica::Regex::SearchLimits.custom(work_ceiling: 10_000_i64)
      match = pattern.match("abcd", limits: tight).should_not be_nil
      match.to_a.should eq(["abcd", "a", "bcd", ""])
    end
  end

  describe "one-pass search" do
    it_satisfies "REGEX-R3-short-search", "finds span and groups in one pass at each prefix-literal candidate" do
      placeholder = expression("\\{\\{([^}]+)\\}\\}")
      found = Mica::Regex::Searcher.open(placeholder.program, "{x {{a} {{name}} y", LIMITS, nil, Mica::Regex::CachePool.default)
      found.find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a).should eq([8, 16, 10, 14])
      found.last_path.should eq(Mica::Regex::Searcher::Path::OnePass)
      found.finish
      separator = expression(",\\s*")
      separator.scan("a,b ,  c,", limits: LIMITS).map { |match| {match.byte_begin, match.byte_end} }
        .should eq([{1, 2}, {4, 7}, {8, 9}])
    end

    it_satisfies "REGEX-R3-short-search", "tries the forward lazy DFA anchored at each candidate when the pattern is not one-pass" do
      separator = expression(",|,\\s")
      separator.program.plan.one_pass.should be_nil
      found = Mica::Regex::Searcher.open(separator.program, "a,b, c", LIMITS, nil, Mica::Regex::CachePool.default)
      found.find(2, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([3, 4])
      found.last_path.should eq(Mica::Regex::Searcher::Path::LazyDFA)
      found.finish
      separator.scan("a,b, c,", limits: LIMITS).map { |match| {match.byte_begin, match.byte_end} }
        .should eq([{1, 2}, {3, 4}, {6, 7}])
      word = expression("\\b(?:ab|a)\\w*c")
      word.program.plan.one_pass.should be_nil
      word.match("xab ab abc", limits: LIMITS).try(&.to_s).should eq("abc")
    end

    it_satisfies "REGEX-R3-short-search", "reads an anchored match and its groups in one pass" do
      route = expression("\\A([a-z]+)-(\\d+)\\z")
      # The first capture pass builds the one-pass DFA; later anchored
      # searches run on it alone.
      route.match("get-1", limits: LIMITS).try(&.[2]).should eq("1")
      found = Mica::Regex::Searcher.open(route.program, "post-42", LIMITS, nil, Mica::Regex::CachePool.default)
      found.find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a).should eq([0, 7, 0, 4, 5, 7])
      found.last_path.should eq(Mica::Regex::Searcher::Path::OnePass)
      found.finish
    end

    it_satisfies "REGEX-R3-short-search", "hands the search to the other paths when a path the one-pass DFA left out could match" do
      # After "aa" the lazy (bb)?? ranks the match below the loop, and the
      # match needs $: at offset 2 it does not hold, and the path through
      # "bb" (left out of the one-pass DFA) is the one that matches.
      pattern = expression("^(aa(bb)??)+$")
      pattern.match("aabbaa", limits: LIMITS).try(&.to_a).should eq(["aabbaa", "aa", "bb"])
      pattern.match("aaaa", limits: LIMITS).try(&.to_a).should eq(["aaaa", "aa", nil])
    end

    it_satisfies "REGEX-R3-short-search", "adds at most the haystack's size to a call when tries at candidates read past their matches" do
      # Each match is one x, but each try reads on through the letters that
      # follow it looking for a longer match. The call counts those bytes
      # and stops trying at candidates once they pass the haystack's size,
      # so it adds at most about n to what the lazy DFAs do alone. The first
      # pattern is one-pass, the second is not (it tries on the lazy DFA).
      {"x(?:[a-z]*b)?", "x(?:[a-z]*b|[a-z]*c)?"}.each do |source|
        pattern = expression(source)
        {500, 1_000, 2_000}.each do |size|
          haystack = "x" * size
          list_of_operations = {Mica::Regex::Engine::Auto, Mica::Regex::Engine::NoAccelerators}.map do |engine|
            searcher = Mica::Regex::Searcher.new(pattern.program, haystack, LIMITS, nil, engine)
            offset = 0
            count = 0
            while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
              offset = found[1].to_i32
              count += 1
            end
            count.should eq(size)
            searcher.finish
            searcher.meter.operations
          end
          (list_of_operations[0] - list_of_operations[1]).should be <= 3 * size + 64
        end
      end
    end
  end

  describe "allocation" do
    it_satisfies "REGEX-R3-short-search", "allocates nothing per call for a pattern without groups" do
      pattern = expression(",\\s*")
      haystack = "ab, cd,ef"
      10.times { pattern.match_at_byte_index(haystack, 0, limits: LIMITS) }
      allocated = bytes_allocated do
        1000.times { pattern.match_at_byte_index(haystack, 0, limits: LIMITS) }
      end
      allocated.should be < 1024
    end
  end

  describe "hot lease" do
    it_satisfies "REGEX-R3-short-search", "evicts an idle lease from the hot slot and from the idle list" do
      step = Mica::Regex::CachePool::RESERVATION_BYTES
      pool = Mica::Regex::CachePool.new(max_bytes: step * 4 + 8192, max_cache_bytes: step)
      first = expression("[a-c]*[a-c]d", pool)
      # Two calls of one program at once: when both finish, one lease goes
      # to the hot slot and the other to the idle list, each with a forward
      # and a reverse cache.
      outer = Mica::Regex::Searcher.open(first.program, "xxabcabd", LIMITS, nil, pool)
      inner = Mica::Regex::Searcher.open(first.program, "xxabcabd", LIMITS, nil, pool)
      outer.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      inner.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      inner.finish
      outer.finish
      pool.reserved_bytes.should be >= step * 4
      # Another program needs both leases' room: each is evicted where it
      # waits, so its DFAs still get caches.
      second = expression("[d-f]*[d-f]g", pool)
      busy = Mica::Regex::Searcher.open(second.program, "xxdefdeg", LIMITS, nil, pool)
      busy.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      busy.dfa_gave_up?.should be_false
      other = Mica::Regex::Searcher.open(second.program, "xxdefdeg", LIMITS, nil, pool)
      other.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([2, 8])
      other.dfa_gave_up?.should be_false
      pool.reserved_bytes.should be <= pool.max_bytes
      {busy, other}.each(&.finish)
      # The evicted leases still work, reserving again.
      first.match("xxabcabd", limits: LIMITS).try(&.to_s).should eq("abcabd")
    end
  end
end
