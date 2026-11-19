require "../spec_helper"

# A program's first single searches run on the bounded backtracker and
# build no plan, lease or lazy-DFA cache (see "First searches" in
# docs/regex.md).
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def fresh_expression(source : String, pool = Mica::Regex::CachePool.default) : Mica::Regex::Expression
  Mica::Regex::Expression.new(source, compile_limits: TRUSTED, cache_pool: pool)
end

# True once the program has built its search plan.
private def plan_built?(pattern : Mica::Regex::Expression) : Bool
  pattern.program.plan_built?
end

describe Mica::Regex::FirstSearch do
  describe ".applies?" do
    it_satisfies "REGEX-R3-first-search", "runs a program's first searches without building its plan" do
      pool = Mica::Regex::CachePool.new
      word = fresh_expression("\\w+\\s+(Holmes)", pool)
      match = word.match("said Sherlock Holmes.", limits: LIMITS).should_not be_nil
      match[0].should eq("Sherlock Holmes")
      match[1].should eq("Holmes")
      word.matches?("no detective here", limits: LIMITS).should be_false
      plan_built?(word).should be_false
      pool.reserved_bytes.should eq(0)
    end

    it_satisfies "REGEX-R3-first-search", "hands later searches to the plan's engines" do
      pattern = fresh_expression("[a-z]+")
      Mica::Regex::FirstSearch::SEARCHES.times { pattern.match("abc", limits: LIMITS).try(&.[0]).should eq("abc") }
      plan_built?(pattern).should be_false
      pattern.match("xyz", limits: LIMITS).try(&.[0]).should eq("xyz")
      plan_built?(pattern).should be_true
    end

    it_satisfies "REGEX-R3-first-search", "leaves long haystacks to the plan" do
      pattern = fresh_expression("[a-z]+!")
      haystack = "a" * (Mica::Regex::FirstSearch::MAX_BYTES + 1) + "!"
      pattern.match(haystack, limits: LIMITS).try(&.byte_end(0)).should eq(haystack.bytesize)
      plan_built?(pattern).should be_true
    end

    it_satisfies "REGEX-R3-first-search", "declines a search whose backtracker work could pass the allowance" do
      tight = Mica::Regex::SearchLimits.custom(work_ceiling: 64, base_work: 64, work_per_byte: 0, work_per_state: 0)
      pattern = fresh_expression("(?:a|b)+c")
      Mica::Regex::FirstSearch.applies?(pattern.program, "ababab", 0, tight).should be_false
      Mica::Regex::FirstSearch.applies?(pattern.program, "ababab", 0, LIMITS).should be_true
    end

    it_satisfies "REGEX-R3-first-search", "reads no haystack and builds nothing for an offset outside it" do
      pattern = fresh_expression("a")
      Mica::Regex::FirstSearch.applies?(pattern.program, "abc", 4, LIMITS).should be_false
      Mica::Regex::FirstSearch.applies?(pattern.program, "abc", -1, LIMITS).should be_false
    end
  end

  it_satisfies "REGEX-R3-first-search", "finds what the plan's engines find, with the same groups" do
    list_of_cases = {
      {"(a+)(b+)?(c)", "xaaabbc aac", 0},
      {"(\\w+)@(\\w+)(\\.\\w+)*", "mail ann@example.co.uk now", 0},
      {"(?i)(x|xy)(y?z)", "XYZ", 0},
      {"(?m)^(\\d+)(?:,(\\d+))*$", "1,2,3\n45", 2},
      {"\\b(?:é|\\w)+\\b", "  ébc d", 1},
      {"a*?", "aaa", 0},
      {"$", "ab\n", 0},
      {"(?s:.)", "\r", 0},
    }
    list_of_cases.each do |source, haystack, offset|
      first = fresh_expression(source)
      aged = fresh_expression(source)
      aged.program.end_first_searches
      expected = aged.match_at_byte_index(haystack, offset, limits: LIMITS)
      found = first.match_at_byte_index(haystack, offset, limits: LIMITS)
      plan_built?(first).should be_false
      found.try(&.to_a).should eq(expected.try(&.to_a))
      found.try(&.byte_begin(0)).should eq(expected.try(&.byte_begin(0)))
      first.matches_at_byte_index?(haystack, offset, limits: LIMITS).should eq(!expected.nil?)
    end
  end

  it_satisfies "REGEX-R3-first-search", "reads the deadline and validates the haystack before it searches" do
    pattern = fresh_expression("a")
    expect_raises(Mica::DeadlineExceededError) do
      pattern.match("a", limits: LIMITS, timeout: -1.second)
    end
    expect_raises(Mica::EncodingError) do
      pattern.match(String.new(Bytes[0x61, 0xFF]), limits: LIMITS)
    end
    plan_built?(pattern).should be_false
  end
end
