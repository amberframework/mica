require "../spec_helper"

private LIMITS = Mica::Regex::SearchLimits::REQUEST

private def compile(source : String, options = Mica::Regex::CompileOptions::None) : Mica::Regex::Expression
  Mica::Regex.compile(source, dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN,
    options: options)
end

private def budget_of(operations : Int64) : Mica::Regex::SearchLimits
  Mica::Regex::SearchLimits.custom(work_ceiling: operations, work_per_byte: 0_i64, work_per_state: 0_i64,
    base_work: operations)
end

# The heap bytes the block allocated.
private def bytes_allocated(& : ->) : UInt64
  before = GC.stats.total_bytes
  yield
  GC.stats.total_bytes - before
end

# Patterns of the Amber corpus (routes, templates, logs, Markdown) and a
# few rebar shapes: literal, alternation, Unicode classes, one-pass and
# not one-pass groups.
private LIST_OF_SOURCES = [
  "\\A[0-9]+\\z", "\\A[a-z0-9]+(?:-[a-z0-9]+)*\\z", "\\{\\{\\s*([a-z_]+)\\s*\\}\\}", ".*:(\\d+)",
  "(\\w+)@(\\w+)\\.com", "Sherlock|Holmes|Watson", "\\b\\w+\\b", "(?i)error", "^(\\d{4})-(\\d{2})-(\\d{2})",
  "'[^']*'", "\\$\\d+", "(a+)+$", "[a-z]+(?:\\s+[a-z]+)*",
]

private HAYSTACK = "GET /posts/2026/my-first-post {{ first_name }} host.example:8080 sherlock@baker.com " \
                   "Sherlock Holmes met Dr. Watson; ERROR at 2026-11-19 'quoted' $1 aaaa résumé naïve"

describe Mica::Regex::Expression do
  describe "#search_span" do
    it "returns the span search finds, without its groups" do
      LIST_OF_SOURCES.each do |source|
        expression = compile(source)
        match = expression.search(HAYSTACK, limits: LIMITS)
        expected = match ? Mica::Regex::Span.new(match.byte_begin(0), match.byte_end(0)) : nil
        expression.search_span(HAYSTACK, limits: LIMITS).should eq(expected)
        expression.search_span(HAYSTACK, 40, limits: LIMITS).should eq(expression.search(HAYSTACK, 40, limits: LIMITS).try { |found| Mica::Regex::Span.new(found.byte_begin(0), found.byte_end(0)) })
      end
    end

    it "raises as search does" do
      expression = compile("[a-z]+")
      expect_raises(ArgumentError, /inside a UTF-8 character/) { expression.search_span("é", 1, limits: LIMITS) }
      expect_raises(Mica::EncodingError) { expression.search_span("ab\xFFcd", limits: LIMITS) }
      expect_raises(Mica::DeadlineExceededError) { expression.search_span("ab", limits: LIMITS, deadline: Time::Span.zero) }
    end
  end

  describe "#search_groups" do
    it "yields every group search reads" do
      LIST_OF_SOURCES.each do |source|
        expression = compile(source)
        expected = expression.search(HAYSTACK, limits: LIMITS).try do |match|
          (0...match.size).map { |group| match[group]? ? {match.byte_begin(group), match.byte_end(group)} : {-1, -1} }
        end
        found = expression.search_groups(HAYSTACK, limits: LIMITS) do |groups|
          (0...groups.size).map { |group| {groups.byte_begin(group), groups.byte_end(group)} }
        end
        found.should eq(expected)
      end
    end

    it "holds more groups than its stack slots in a heap buffer" do
      source = (1..40).map { |group| "(#{('a'.ord + group % 26).chr})" }.join
      haystack = (1..40).map { |group| ('a'.ord + group % 26).chr }.join
      compile(source).search_groups(haystack, limits: LIMITS) { |groups| {groups.size, groups[40]?} }
        .should eq({41, haystack[39].to_s})
    end
  end

  describe "#each_span" do
    it "yields the spans each_match finds" do
      LIST_OF_SOURCES.each do |source|
        expression = compile(source)
        expected = [] of Mica::Regex::Span
        expression.each_match(HAYSTACK, limits: LIMITS) { |match| expected << Mica::Regex::Span.new(match.byte_begin(0), match.byte_end(0)) }
        found = [] of Mica::Regex::Span
        expression.each_span(HAYSTACK, limits: LIMITS) { |span| found << span }
        found.should eq(expected)
      end
    end

    it "spends one work budget across the whole call" do
      expression = compile("a")
      haystack = "ab" * 500
      expression.search_span(haystack, limits: budget_of(1_200)).should eq(Mica::Regex::Span.new(0, 1))
      error = expect_raises(Mica::Regex::SearchLimitError) do
        expression.each_span(haystack, limits: budget_of(1_200)) { }
      end
      error.limit_name.should eq("max_work")
    end
  end

  it "allocates nothing per search once the expression has adapted" do
    list_of_expressions = LIST_OF_SOURCES.map { |source| compile(source) }
    # The first searches build each plan, its caches and its parked searcher,
    # and the 16th group read builds the program's fewest-bytes table
    # (`Program::MIN_BYTES_AFTER`).
    32.times do
      list_of_expressions.each do |expression|
        expression.search_span(HAYSTACK, limits: LIMITS)
        expression.matches?(HAYSTACK, limits: LIMITS)
        expression.search_groups(HAYSTACK, limits: LIMITS) { |groups| groups.byte_end(0) }
        expression.each_span(HAYSTACK, limits: LIMITS) { |span| span.bytesize }
      end
    end
    list_of_expressions.each do |expression|
      allocated = bytes_allocated do
        200.times do
          expression.search_span(HAYSTACK, limits: LIMITS)
          expression.matches?(HAYSTACK, limits: LIMITS)
          expression.search_groups(HAYSTACK, limits: LIMITS) { |groups| groups.byte_end(0) }
          expression.each_span(HAYSTACK, limits: LIMITS) { |span| span.bytesize }
        end
      end
      {expression.source, allocated}.should eq({expression.source, 0_u64})
    end
  end
end
