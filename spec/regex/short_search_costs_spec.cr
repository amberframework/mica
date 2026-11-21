require "../spec_helper"

# The fixed costs of a short single search, cut in round 4: a match's
# groups read in the backtracker pass that finds its start, a
# fixed-length match's start taken from its end, a haystack a short
# search validated not read again (but still charged), and a match value
# that keeps its deferred groups behind one address.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT
private NONE    = Mica::Regex::MatchOptions::None

# An expression past its first searches (see first_search_spec.cr), so
# every search here takes the plan's engines.
private def planned_expression(source : String) : Mica::Regex::Expression
  pattern = Mica::Regex::Expression.new(source, compile_limits: TRUSTED)
  pattern.program.end_first_searches
  pattern
end

# Every match of *pattern* in *haystack*, with its groups, as `String#scan`
# finds them.
private def scan_groups(pattern : Mica::Regex::Expression, haystack : String) : Array(Array(String?))
  list_of_matches = [] of Array(String?)
  offset = 0
  while offset <= haystack.bytesize
    match = pattern.search(haystack, offset, limits: LIMITS)
    break unless match
    list_of_matches << Array(String?).new(match.size) { |group| match[group]? }
    offset = match.byte_end(0) > match.byte_begin(0) ? match.byte_end(0) : match.byte_end(0) + 1
  end
  list_of_matches
end

describe "Mica::Regex short search costs" do
  describe "groups read with the span" do
    it_satisfies "REGEX-R3-selection", "reads a short match's groups in the backtracker pass that finds its start" do
      pattern = planned_expression(".*:(\\d+)")
      haystack = "example.com:5482"
      # The first search's capture pass finds the program is not one-pass.
      3.times { scan_groups(pattern, haystack).should eq([["example.com:5482", "5482"]]) }
      pattern.program.plan.built_one_pass.should be_nil
      searcher = Mica::Regex::Searcher.open(pattern.program, haystack, LIMITS, nil, Mica::Regex::CachePool.default)
      slots = searcher.find(0, NONE, true)
      slots.try(&.to_a).should eq([0, 16, 12, 16])
      searcher.last_path.should eq(Mica::Regex::Searcher::Path::LazyDFA)
      searcher.finish
    end

    it_satisfies "REGEX-R3-selection", "stops groups read with the span at the call's allowance" do
      pattern = planned_expression(".*:(\\d+)")
      haystack = "test.example.co.uk:7702"
      3.times { scan_groups(pattern, haystack) }
      pool = Mica::Regex::CachePool.default
      unlimited = Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX // 2, work_per_byte: 1_000_000_i64)
      searcher = Mica::Regex::Searcher.open(pattern.program, haystack, unlimited, nil, pool)
      searcher.find(0, NONE, true).try(&.to_a).should eq([0, 23, 19, 23])
      total = searcher.meter.operations
      searcher.finish
      (haystack.bytesize.to_i64 + 1).upto(total) do |ceiling|
        limits = Mica::Regex::SearchLimits.custom(work_ceiling: ceiling, work_per_byte: 1_000_000_i64)
        searcher = Mica::Regex::Searcher.open(pattern.program, haystack, limits, nil, pool)
        begin
          searcher.find(0, NONE, true).try(&.to_a).should eq([0, 23, 19, 23])
          searcher.meter.operations.should be <= ceiling
        rescue error : Mica::Regex::SearchLimitError
          error.limit_name.should eq("max_work")
          error.message.to_s[/A search of (\d+) operations/, 1].to_i64.should eq(ceiling + 1)
        ensure
          searcher.finish
        end
      end
    end

    it_satisfies "REGEX-R3-selection", "goes on with the reverse DFA when no match starts at the offset" do
      pattern = planned_expression(".*:(\\d+)")
      3.times { scan_groups(pattern, "a:1") }
      # `.` stops at the line feed, so the match starts after it.
      scan_groups(pattern, "ab\nhost:80\nx:7").should eq([["host:80", "80"], ["x:7", "7"]])
      scan_groups(pattern, "no port\n:9").should eq([[":9", "9"]])
    end

    it_satisfies "REGEX-R3-selection", "agrees with the Pike VM on groups read with the span" do
      list_of_cases = {
        {"(a|ab)(c|bcd)(d*)", "abcd xabcd"},
        {"([a-z]+)@([a-z]+)\\.(com|org)", "x ann@example.org bob@host.com"},
        {"\\b(\\w+) (\\w+)\\b", "hello world foo bar"},
        {"(?m)^(\\w+):(.*)$", "key:value\nother:thing"},
      }
      list_of_cases.each do |source, haystack|
        pattern = planned_expression(source)
        expected = [] of Array(Int64)
        offset = 0
        while offset <= haystack.bytesize
          pike = Mica::Regex::Searcher.new(pattern.program, haystack, LIMITS, nil, Mica::Regex::Engine::PikeVM)
          found = pike.find(offset, NONE, true)
          pike.finish
          break unless found
          expected << found.to_a
          offset = found[1] > found[0] ? found[1].to_i32 : found[1].to_i32 + 1
        end
        2.times do
          offset = 0
          actual = [] of Array(Int64)
          while offset <= haystack.bytesize
            searcher = Mica::Regex::Searcher.open(pattern.program, haystack, LIMITS, nil, Mica::Regex::CachePool.default)
            found = searcher.find(offset, NONE, true)
            copy = found.try(&.to_a)
            searcher.finish
            break unless copy
            actual << copy
            offset = copy[1] > copy[0] ? copy[1].to_i32 : copy[1].to_i32 + 1
          end
          actual.should eq(expected)
        end
      end
    end
  end

  describe "fixed-length matches" do
    it_satisfies "REGEX-R3-short-match", "knows when every match has one length in bytes" do
      planned_expression("[a-z]{5}").program.plan.fixed_match_bytes.should eq(5)
      planned_expression("\\b[a-z]{3}\\b").program.plan.fixed_match_bytes.should eq(3)
      planned_expression("a|bc").program.plan.fixed_match_bytes.should eq(-1)
      # `é` is two bytes and `e` one.
      planned_expression("(?:é|e)x").program.plan.fixed_match_bytes.should eq(-1)
      planned_expression("a+").program.plan.fixed_match_bytes.should eq(-1)
    end

    it_satisfies "REGEX-R3-short-match", "takes a fixed-length match's start from its end" do
      pattern = planned_expression("[a-z]{5}")
      haystack = "then as it was, then again it will be. yesterday's weather"
      scan_groups(pattern, haystack).map(&.first).should eq(["again", "yeste", "weath"])
      unicode = planned_expression("\\b\\w{2}é\\b")
      scan_groups(unicode, "un café, thé et abé").map(&.first).should eq(["thé", "abé"])
    end
  end

  describe "validation" do
    it_satisfies "REGEX-R3-short-search", "charges a haystack a short search found valid as it charges any other" do
      program = planned_expression("[a-c]*[a-c]d").program
      plan = program.plan
      remembered = String.build { |io| io << "xxabcabd" }
      fresh = String.build { |io| io << "xxabcabd" }
      plan.remember_short_validated(remembered)
      list_of_operations = {remembered, fresh}.map do |haystack|
        searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil)
        operations = searcher.meter.operations
        searcher.finish
        operations
      end
      list_of_operations.should eq({8_i64, 8_i64})
    end
  end

  describe "deferred groups" do
    it_satisfies "REGEX-R3-short-search", "keeps a match small and shares its groups once read" do
      sizeof(Mica::Regex::MatchData).should be <= 88
      email = planned_expression("\\A[\\w+\\-.]+@[a-z\\d\\-]+(\\.[a-z\\d\\-]+)*\\.[a-z]+\\z")
      email.match("ann@mail.example.org", limits: LIMITS)
      match = email.match("ann@mail.example.org", limits: LIMITS) || fail "no match"
      copy = match
      match[1]?.should eq(".example")
      copy[1]?.should eq(".example")
      copy.byte_begin(1).should eq(8)
      email.match("a@b.c", limits: LIMITS).try(&.[1]?).should be_nil
    end
  end
end
