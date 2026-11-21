require "../spec_helper"
require "../../src/mica/regex/static/write_the_source"

private ROUTE_ID         = Mica::Regex.static(/\A[0-9]+\z/)
private UNICODE_DIGITS   = Mica::Regex.static(/\A\d+\z/)
private LONG_RUN         = Mica::Regex.static("[a-z]{300}")
private HOST_PORT        = Mica::Regex.static(".*:(\\d+)")
private PLACEHOLDER      = Mica::Regex.static(/\{\{\s*([a-z_]+)\s*\}\}/i)
private SLUG             = Mica::Regex.static("[a-z0-9]+(?:-[a-z0-9]+)*")
private WORD_START       = Mica::Regex.static("\\bfoo")
private LONG_UNICODE_RUN = Mica::Regex.static("\\p{L}{256}")
private EMPTY_RUNS       = Mica::Regex.static("a*")

private LIMITS = Mica::Regex::SearchLimits::REQUEST

private def runtime(source : String, options = Mica::Regex::CompileOptions::None) : Mica::Regex::Expression
  Mica::Regex.compile(source, dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN,
    options: options)
end

# A budget of *operations* in all, whatever the haystack and the program.
private def budget_of(operations : Int64) : Mica::Regex::SearchLimits
  Mica::Regex::SearchLimits.custom(work_ceiling: operations, work_per_byte: 0_i64, work_per_state: 0_i64,
    base_work: operations)
end

private def emitted(source : String) : String
  result = Mica::Regex::Static::BuildTheTables.new(source, Mica::Regex::CompileOptions::None).perform
  String.build { |io| Mica::Regex::Static::WriteTheSource.new(result, io).perform }
end

describe Mica::Regex::StaticPattern do
  describe ".static" do
    it "holds a small pattern in UInt8 state ids" do
      ROUTE_ID.static?.should be_true
      typeof(ROUTE_ID).to_s.should start_with("Mica::Regex::StaticPattern(UInt8, UInt8, UInt8, ")
    end

    it "widens to UInt16 state ids for a DFA over 255 states" do
      typeof(LONG_RUN).to_s.should start_with("Mica::Regex::StaticPattern(UInt16, UInt16, UInt8, ")
      LONG_RUN.search_span("1" + "a" * 301).should eq(Mica::Regex::Span.new(1, 301))
    end

    it "shares one matcher between patterns of the same widths" do
      typeof(ROUTE_ID.@matcher).should eq(typeof(PLACEHOLDER.@matcher))
      typeof(ROUTE_ID).should_not eq(typeof(PLACEHOLDER))
    end

    it "reads Unicode classes" do
      UNICODE_DIGITS.matches?("٢٠٢٦").should be_true
      ROUTE_ID.matches?("٢٠٢٦").should be_false
    end

    it "leaves a pattern outside the static limits on the runtime engine, with the same methods" do
      LONG_UNICODE_RUN.static?.should be_false
      LONG_UNICODE_RUN.reason.should contain("states")
      haystack = "1" + "é" * 256
      LONG_UNICODE_RUN.matches?(haystack).should be_true
      LONG_UNICODE_RUN.search_span(haystack).should eq(Mica::Regex::Span.new(1, 513))
      LONG_UNICODE_RUN.search_groups(haystack) { |groups| groups.byte_end(0) }.should eq(513)
      list_of_spans = [] of Mica::Regex::Span
      LONG_UNICODE_RUN.each_span(haystack) { |span| list_of_spans << span }
      list_of_spans.should eq([Mica::Regex::Span.new(1, 513)])
    end

    it "writes a fallback with a note naming the limit it passed" do
      kind, note, _ = emitted("\\p{L}{256}").split('\n', 3)
      kind.should eq("fallback")
      note.should contain("stays on the runtime engine: its forward DFA has more than 4096 states")
    end

    it "reports a pattern the runtime compiler rejects as a compile error" do
      kind, note, _ = emitted("a(?=b)").split('\n', 3)
      kind.should eq("error")
      note.should contain("lookahead is outside the Mica::Regex dialect")
    end
  end

  describe "#matches?" do
    it "answers as the runtime engine does" do
      ROUTE_ID.matches?("2026").should be_true
      ROUTE_ID.matches?("2026x").should be_false
      ROUTE_ID.matches?("").should be_false
      SLUG.matches?("--a", 2).should be_true
      SLUG.matches?("a--", 3).should be_false
    end
  end

  describe "#search_span" do
    it "finds the leftmost-first span from an offset" do
      SLUG.search_span("-- my-first-post --", 2).should eq(Mica::Regex::Span.new(3, 16))
    end

    it "reads Unicode word boundaries" do
      WORD_START.search_span("éfoo foo").should eq(Mica::Regex::Span.new(6, 9))
      runtime("\\bfoo").search_span("éfoo foo", limits: LIMITS).should eq(Mica::Regex::Span.new(6, 9))
    end

    it "raises on a start inside a character and on invalid UTF-8" do
      expect_raises(ArgumentError, /inside a UTF-8 character/) { SLUG.search_span("é", 1) }
      expect_raises(Mica::EncodingError) { SLUG.search_span("ab\xFFcd") }
    end

    it "raises the named limit when the work budget runs out" do
      error = expect_raises(Mica::Regex::SearchLimitError) { SLUG.search_span("a" * 1_000 + "!", limits: budget_of(64)) }
      error.limit_name.should eq("max_work")
    end

    it "raises when the deadline has already passed" do
      expect_raises(Mica::DeadlineExceededError) { SLUG.search_span("a-b", deadline: Time::Span.zero) }
    end
  end

  describe "#search_groups" do
    it "reads the groups of a one-pass pattern and of one the Pike VM reads" do
      PLACEHOLDER.search_groups("Hello {{ First_Name }}!") { |groups| groups[1]? }.should eq("First_Name")
      HOST_PORT.search_groups("example.com:8080") { |groups| {groups[1]?, groups.byte_begin(1), groups.span?(1)} }
        .should eq({"8080", 12, Mica::Regex::Span.new(12, 16)})
    end

    it "returns nil when nothing matches" do
      HOST_PORT.search_groups("example.com") { |groups| groups[1]? }.should be_nil
    end

    it "raises IndexError for a group the pattern does not have" do
      expect_raises(IndexError) { HOST_PORT.search_groups("a:1") { |groups| groups.byte_begin(2) } }
    end
  end

  describe "#each_span" do
    it "iterates as String#scan does, stepping over a character after an empty match" do
      list_of_spans = [] of Mica::Regex::Span
      EMPTY_RUNS.each_span("baé") { |span| list_of_spans << span }
      list_of_spans.map { |span| {span.byte_begin, span.byte_end} }.should eq([{0, 0}, {1, 2}, {2, 2}, {4, 4}])
    end

    it "spends one work budget across the whole call" do
      letter_a = Mica::Regex.static("a")
      haystack = "ab" * 500
      letter_a.search_span(haystack, limits: budget_of(1_500)).should eq(Mica::Regex::Span.new(0, 1))
      matches = 0
      error = expect_raises(Mica::Regex::SearchLimitError) do
        letter_a.each_span(haystack, limits: budget_of(1_500)) { matches += 1 }
      end
      error.limit_name.should eq("max_work")
      matches.should be < 500
    end

    it "raises max_work when a search needs exactly one operation more than its allowance" do
      # Validation takes 1,000 operations and the scan reads the other 500
      # before it needs one more.
      error = expect_raises(Mica::Regex::SearchLimitError) { SLUG.search_span("ab" * 500, limits: budget_of(1_500)) }
      error.limit_name.should eq("max_work")
    end
  end

  it "allocates nothing per search" do
    haystack = "routes: 2026 example.com:8080 {{ name }} my-first-post"
    SLUG.search_span(haystack)
    before = GC.stats.total_bytes
    1_000.times do
      SLUG.search_span(haystack)
      ROUTE_ID.matches?(haystack)
      UNICODE_DIGITS.matches?("٢٠٢٦")
      HOST_PORT.search_groups(haystack) { |groups| groups.byte_end(1) }
      PLACEHOLDER.search_groups(haystack) { |groups| groups.byte_begin(1) }
      EMPTY_RUNS.each_span(haystack) { |span| span.bytesize }
    end
    (GC.stats.total_bytes - before).should eq(0)
  end
end
