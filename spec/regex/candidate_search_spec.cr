require "../spec_helper"

# The per-call path of a single search over a long haystack the plan has
# validated (`CandidateSearch`): the one-pass DFA tried at each candidate
# start, with no lease, no searcher and no meter, its whole work checked
# against the allowance before it reads the haystack.
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

# Searches *haystack* once on the searcher, so the plan remembers it as
# valid, and enough times for the one-pass DFA to be built.
private def warm(pattern : Mica::Regex::Expression, haystack : String) : Nil
  (Mica::Regex::ShortSearch::BUILD_AFTER + 1).times { pattern.match_at_byte_index(haystack, 0, limits: LIMITS) }
end

# Every match of *haystack*, one `match_at_byte_index` call each, as
# `String#scan` makes them, with every group's byte span.
private def calls(pattern : Mica::Regex::Expression, haystack : String,
                  limits = LIMITS) : Array(Array(Int32))
  list_of_matches = [] of Array(Int32)
  offset = 0
  while match = pattern.match_at_byte_index(haystack, offset, limits: limits)
    list_of_matches << (0...match.size).flat_map { |group| match[group]? ? [match.byte_begin(group), match.byte_end(group)] : [-1, -1] }
    offset = match.byte_end(0) > match.byte_begin(0) ? match.byte_end(0) : match.byte_end(0) + 1
  end
  list_of_matches
end

# The same matches from R2's two-phase search, one searcher per call.
private def two_phase(pattern : Mica::Regex::Expression, haystack : String) : Array(Array(Int32))
  list_of_matches = [] of Array(Int32)
  offset = 0
  while offset <= haystack.bytesize
    searcher = Mica::Regex::Searcher.new(pattern.program, haystack, LIMITS, nil, Mica::Regex::Engine::TwoPhase)
    slots = searcher.find(offset, NONE, true)
    searcher.finish
    break unless slots
    list_of_matches << slots.to_a.map(&.to_i32)
    offset = slots[1] > slots[0] ? slots[1].to_i32 : slots[1].to_i32 + 1
  end
  list_of_matches
end

# Runs one candidate search from *offset*: its answer, or nil when it
# does not apply.
private def candidate_answer(pattern : Mica::Regex::Expression, haystack : String, offset : Int32,
                             limits = LIMITS, timeout : Time::Span? = nil) : {Int32, Int64}?
  search = Mica::Regex::CandidateSearch.new(pattern.program, pattern.program.plan, haystack, offset, NONE, limits, timeout)
  one_pass = search.one_pass || return nil
  buffer = Slice(Int64).new(2 * Mica::Regex::CandidateSearch::MAX_SLOTS, -1_i64)
  slot_count = pattern.program.slot_count
  finish = search.run(one_pass, buffer[0, slot_count], buffer[Mica::Regex::CandidateSearch::MAX_SLOTS, slot_count])
  {finish, search.spent}
end

# The start filter of *source* with its second bytes collected, as a
# candidate search collects them.
private def prepared_filter(source : String) : Mica::Regex::StartFilter
  program = planned_expression(source).program
  filter = program.plan.start_filter
  filter.prepare_second_bytes(program)
  filter
end

private def bytes_allocated(&) : Int64
  before = allocated_bytes_so_far
  yield
  (allocated_bytes_so_far - before).to_i64
end

describe "Mica::Regex candidate searches" do
  it_satisfies "REGEX-R3-short-search", "answers separate calls over a long haystack as the two-phase search does" do
    {
      ",\\s*"                   => "a, b,c,  d" * 60,
      "[^a-z0-9]+"              => "user_name-id.42 fooBar" * 40,
      "\\{\\{([^}]+)\\}\\}"     => "Hi {{ name }}, { no } {{x\ny}} {{ open\n" * 30,
      "([a-zA-Z0-9_$']+)"       => "SELECT 'x', $1 FROM t WHERE a = 42;" * 30,
      "\\b\\d+\\b"              => "id 42 x7 1000 é9 " * 40,
      "(?<k>[a-z]+)=(?<v>\\d+)" => "a=1 bb=22 c= é=3 " * 40,
    }.each do |source, haystack|
      pattern = planned_expression(source)
      warm(pattern, haystack)
      candidate_answer(pattern, haystack, 0).should_not be_nil
      calls(pattern, haystack).should eq(two_phase(pattern, haystack))
    end
  end

  it_satisfies "REGEX-R3-short-search", "tries only positions whose next byte a match can have second" do
    camel = prepared_filter("([a-z\\d])([A-Z])")
    camel.second?('A'.ord.to_u8).should be_true
    camel.second?('b'.ord.to_u8).should be_false
    pixels = prepared_filter("\\d+px")
    {pixels.second?('7'.ord.to_u8), pixels.second?('p'.ord.to_u8), pixels.second?('x'.ord.to_u8)}.should eq({true, true, false})
    # A match can be one byte long, so every byte may follow.
    short = prepared_filter("a|bc")
    short.second?('z'.ord.to_u8).should be_true
  end

  it_satisfies "REGEX-R3-short-search", "keeps a match of up to four groups in the value, so a call allocates nothing" do
    pattern = planned_expression("([a-z])([A-Z])")
    haystack = "camelCaseWordsHere and more " * 20
    warm(pattern, haystack)
    candidate_answer(pattern, haystack, 0).should_not be_nil
    pattern.match_at_byte_index(haystack, 1, limits: LIMITS)
    bytes_allocated { pattern.match_at_byte_index(haystack, 1, limits: LIMITS) }.should eq(0)
    match = pattern.match_at_byte_index(haystack, 1, limits: LIMITS).should_not be_nil
    match.to_a.should eq(["lC", "l", "C"])
    match.should eq(pattern.match_at_byte_index(haystack, 0, limits: LIMITS))
  end

  it_satisfies "REGEX-R3-short-search", "leaves a search with a timeout to the searcher, which reads the deadline first" do
    pattern = planned_expression(",\\s*")
    haystack = "a, b" * 100
    warm(pattern, haystack)
    candidate_answer(pattern, haystack, 0, timeout: 1.second).should be_nil
    expect_raises(Mica::DeadlineExceededError) do
      pattern.match_at_byte_index(haystack, 0, limits: LIMITS, timeout: -1.second)
    end
  end

  it_satisfies "REGEX-R3-complexity", "declines when its most work does not fit the allowance, and the searcher stops on max_work" do
    pattern = planned_expression(",\\s*")
    haystack = "a" * 2000 + ","
    warm(pattern, haystack)
    tight = Mica::Regex::SearchLimits.custom(work_ceiling: 1_000_i64)
    candidate_answer(pattern, haystack, 0, tight).should be_nil
    expect_raises(Mica::Regex::SearchLimitError, /max_work/) do
      # A copy of the haystack, so no earlier call's validation or scan
      # positions carry over.
      pattern.match_at_byte_index(String.new(haystack.to_slice), 0, limits: tight)
    end
  end

  it_satisfies "REGEX-R3-complexity", "stays within 3n plus a constant however far its failed tries read" do
    pattern = planned_expression("a[^z]*z")
    bounds = [1_000, 4_000, 16_000].map do |size|
      haystack = "a" * size
      warm(pattern, haystack)
      answer = candidate_answer(pattern, haystack, 0).should_not be_nil
      answer[0].should_not eq(Mica::Regex::LazyDFA::NO_MATCH)
      spent = answer[1]
      overshoot = (Mica::Regex::CandidateSearch::MAX_TRIES + 1) * (Mica::Regex::CandidateSearch::TRY_REACH + 1) + 2
      spent.should be <= 3_i64 * size + overshoot
      pattern.match_at_byte_index(haystack, 0, limits: LIMITS).should be_nil
      spent
    end
    # Linear: four times the bytes, at most about four times the work.
    (bounds[2].to_f / bounds[1]).should be < 4.5
  end

  it "finds runs of a class whose literals are single bytes on the start table, as the two-phase search does" do
    pattern = planned_expression("[ \\t\\n\\x0b\\x0c\\x0d]+")
    random = Random.new(20261121)
    pieces = ["word", " ", "  ", "\t", "\n", "é", "x\r\n"]
    20.times do
      haystack = String.build { |io| random.rand(1..120).times { io << pieces.sample(random) } }
      warm(pattern, haystack)
      calls(pattern, haystack).should eq(two_phase(pattern, haystack))
    end
    haystack = "ab  cd\te"
    warm(pattern, haystack)
    answer = candidate_answer(pattern, haystack, 0).should_not be_nil
    answer[0].should eq(4)
  end

  it_satisfies "REGEX-R3-complexity", "declines a single-byte literal set past a long stretch with no start, and the searcher answers" do
    pattern = planned_expression("[ \\t]+")
    haystack = "a" * (Mica::Regex::CandidateSearch::SPARSE_SCAN_BYTES * 4) + " \t"
    warm(pattern, haystack)
    answer = candidate_answer(pattern, haystack, 0).should_not be_nil
    answer[0].should eq(Mica::Regex::LazyDFA::GAVE_UP)
    answer[1].should be <= Mica::Regex::CandidateSearch::SPARSE_SCAN_BYTES + 1
    match = pattern.match_at_byte_index(haystack, 0, limits: LIMITS).should_not be_nil
    match.byte_begin(0).should eq(Mica::Regex::CandidateSearch::SPARSE_SCAN_BYTES * 4)
    match.byte_end(0).should eq(haystack.bytesize)
  end
end
