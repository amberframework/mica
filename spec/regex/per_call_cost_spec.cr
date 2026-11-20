require "../spec_helper"

# Round 6 per-call tuning: short searches under a positive timeout, searches
# anchored at the offset when the empty string matches everywhere, DFA and
# one-pass runs over a match state that loops to itself, the required bytes
# a prefix literal lacks, and one clock read as a call starts. Each answer
# is checked against the Pike VM, which takes none of these paths.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT
private REQUEST = Mica::Regex::SearchLimits::REQUEST

# An expression past its first searches (see first_search_spec.cr), so
# every search here takes the plan's engines.
private def planned_expression(source : String, options = Mica::Regex::CompileOptions::None) : Mica::Regex::Expression
  pattern = Mica::Regex::Expression.new(source, options, compile_limits: TRUSTED)
  pattern.program.end_first_searches
  pattern
end

# The span of the leftmost-first match from *byte_index* on the Pike VM.
private def pike_span(expression : Mica::Regex::Expression, haystack : String, byte_index : Int32 = 0,
                      options : Mica::Regex::MatchOptions = Mica::Regex::MatchOptions::None) : {Int64, Int64}?
  searcher = Mica::Regex::Searcher.new(expression.program, haystack, LIMITS, nil, Mica::Regex::Engine::PikeVM)
  found = searcher.find(byte_index, options, false)
  found ? {found[0], found[1]} : nil
ensure
  searcher.try(&.finish)
end

private def auto_span(expression : Mica::Regex::Expression, haystack : String, byte_index : Int32 = 0,
                      options : Mica::Regex::MatchOptions = Mica::Regex::MatchOptions::None,
                      timeout : Time::Span? = nil) : {Int64, Int64}?
  match = expression.match_at_byte_index(haystack, byte_index, options, limits: REQUEST, timeout: timeout)
  match ? {match.byte_begin(0).to_i64, match.byte_end(0).to_i64} : nil
end

describe "Mica::Regex per-call costs" do
  describe "short searches under a timeout" do
    it_satisfies "REGEX-R3-short-search", "answer under a positive timeout as the searcher does" do
      {"(x+x+)+y", "(.*a){20}", "(a|a)*b", "\\s+$", "[a-z]+@[a-z]+"}.each do |source|
        expression = planned_expression(source)
        {"x" * 16, "a" * 16, "x" + " " * 16 + "x", "ann@example", "xxy", "a" * 20 + "b"}.each do |haystack|
          answer = auto_span(expression, haystack, timeout: 1.second)
          {source, haystack, answer}.should eq({source, haystack, pike_span(expression, haystack)})
        end
      end
    end

    it_satisfies "REGEX-R2-limits", "still fail as the call starts when the timeout is zero or negative" do
      expression = planned_expression("(x+x+)+y")
      {Time::Span.zero, -1.second}.each do |timeout|
        expect_raises(Mica::DeadlineExceededError) { expression.match("x" * 16, limits: REQUEST, timeout: timeout) }
        expect_raises(Mica::DeadlineExceededError) { expression.match("x" * 4096, limits: REQUEST, timeout: timeout) }
      end
    end
  end

  describe "a pattern whose empty match is everywhere" do
    it_satisfies "REGEX-R3-dfa", "runs anchored at the offset and finds the leftmost-first match" do
      {".*", "(?s).*", "(a*)", "a*b*", "(?:x|)y*", "[^\\n]*"}.each do |source|
        expression = planned_expression(source)
        expression.program.plan.empty_match_everywhere?.should be_true
        {"", "baa", "xyyy\nzz", "line one\nline two", "é" * 40 + "\n" + "a" * 300}.each do |haystack|
          [0, 1, haystack.bytesize].uniq.select { |offset| offset <= haystack.bytesize }.each do |offset|
            next unless offset == haystack.bytesize || haystack.byte_at(offset) & 0xC0 != 0x80
            answer = auto_span(expression, haystack, offset)
            {source, haystack, offset, answer}.should eq({source, haystack, offset, pike_span(expression, haystack, offset)})
          end
        end
      end
    end

    it_satisfies "REGEX-R3-dfa", "does not count the empty match when the match must end at the end" do
      expression = planned_expression("a*")
      end_anchored = Mica::Regex::MatchOptions::EndAnchored
      auto_span(expression, "baa", 0, end_anchored).should eq({1_i64, 3_i64})
      pike_span(expression, "baa", 0, end_anchored).should eq({1_i64, 3_i64})
      planned_expression("\\ba*").program.plan.empty_match_everywhere?.should be_false
    end
  end

  describe "a match state that loops to itself" do
    it_satisfies "REGEX-R3-dfa", "ends the match where an ASCII run in a match state stops" do
      expression = planned_expression("[\\x00-\\x7f]*")
      haystack = "a" * 5_000 + "é" + "b" * 10
      auto_span(expression, haystack).should eq({0_i64, 5_000_i64})
      expression.match(haystack, limits: LIMITS).try(&.byte_end(0)).should eq(5_000)
      everything = planned_expression("(?s).*")
      sherlock_like = "\u{FEFF}" + ("The adventure of the speckled band.\r\n" * 2_000) + "end"
      3.times { everything.match(sherlock_like, limits: LIMITS).try(&.byte_end(0)).should eq(sherlock_like.bytesize) }
    end

    it_satisfies "REGEX-R3-one-pass", "reads the groups of a match that ends where a looping match state's run stops" do
      expression = planned_expression("(\\w+):(.*)")
      9.times { expression.match("key:value one\nnext", limits: LIMITS) }
      match = expression.match("key:value one\nnext", limits: LIMITS).should_not be_nil
      match.to_a.should eq(["key:value one", "key", "value one"])
      line = planned_expression(".*")
      9.times { line.match("first line\nsecond", limits: LIMITS) }
      line.match("first line\nsecond", limits: LIMITS).try(&.[0]).should eq("first line")
      line.match("first line\nsecond", 10, limits: LIMITS).try(&.[0]).should eq("")
    end
  end

  describe "required bytes past the prefix literals" do
    it_satisfies "REGEX-R3-required-bytes", "rejects a haystack that has the literal but lacks a byte past it" do
      expression = planned_expression("(x+x+)+y")
      expression.program.plan.list_of_required_bytes_past_literals.should eq(['y'.ord.to_u8])
      expression.match("x" * 1024, limits: REQUEST, timeout: 1.second).should be_nil
      expression.match("x" * 1024 + "y", limits: REQUEST, timeout: 1.second).try(&.byte_end(0)).should eq(1025)
      planned_expression("abc").program.plan.list_of_required_bytes_past_literals.should be_empty
    end
  end
end
