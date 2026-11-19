require "../spec_helper"

private ROUTE_ID         = Mica::Regex.static(/\A[0-9]+\z/)
private UNICODE_DIGITS   = Mica::Regex.static(/\A\d+\z/)
private HOST_PORT        = Mica::Regex.static(".*:(\\d+)")
private PLACEHOLDER      = Mica::Regex.static(/\{\{\s*([a-z_]+)\s*\}\}/i)
private SLUG             = Mica::Regex.static("[a-z0-9]+(?:-[a-z0-9]+)*")
private WORD_START       = Mica::Regex.static("\\bfoo")
private LONG_UNICODE_RUN = Mica::Regex.static("\\p{L}{256}")

private def runtime(source : String, options = Mica::Regex::CompileOptions::None) : Mica::Regex::Expression
  Mica::Regex.compile(source, dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN,
    options: options)
end

describe Mica::Regex::StaticPattern do
  describe ".static" do
    it "holds a small pattern in the narrowest tables" do
      ROUTE_ID.static?.should be_true
      typeof(ROUTE_ID).to_s.should start_with("Mica::Regex::StaticPattern(UInt8, UInt8")
    end

    it "widens the tables a Unicode class needs" do
      typeof(UNICODE_DIGITS).to_s.should start_with("Mica::Regex::StaticPattern(UInt16, UInt16")
      UNICODE_DIGITS.matches?("٢٠٢٦").should be_true
    end

    it "leaves a pattern whose automaton is too large on the runtime engine" do
      LONG_UNICODE_RUN.static?.should be_false
      LONG_UNICODE_RUN.reason.should contain("states")
    end
  end

  describe "#matches?" do
    it "answers as the runtime engine does" do
      ROUTE_ID.matches?("2026").should be_true
      ROUTE_ID.matches?("2026x").should be_false
      ROUTE_ID.matches?("").should be_false
    end
  end

  describe "#search" do
    it "finds the leftmost-first span from an offset" do
      span = SLUG.search("-- my-first-post --", 2)
      span.should eq(Mica::Regex::StaticSpan.new(3, 16))
    end

    it "reads Unicode word boundaries" do
      WORD_START.search("éfoo foo").should eq(Mica::Regex::StaticSpan.new(6, 9))
      runtime("\\bfoo").search("éfoo foo", limits: Mica::Regex::SearchLimits::REQUEST).try(&.byte_begin(0)).should eq(6)
    end

    it "raises on a start inside a character and on invalid UTF-8" do
      expect_raises(ArgumentError, /inside a UTF-8 character/) { SLUG.search("é", 1) }
      expect_raises(Mica::EncodingError) { SLUG.search("ab\xFFcd") }
    end

    it "raises the named limit when the work budget runs out" do
      limits = Mica::Regex::SearchLimits.custom(work_ceiling: 64_i64, work_per_byte: 0_i64, work_per_state: 0_i64,
        base_work: 64_i64)
      error = expect_raises(Mica::Regex::SearchLimitError) { SLUG.search("a" * 1_000 + "!", limits: limits) }
      error.limit_name.should eq("max_work")
    end

    it "raises when the deadline has already passed" do
      expect_raises(Mica::DeadlineExceededError) { SLUG.search("a-b", deadline: Time::Span.zero) }
    end
  end

  describe "#search_groups" do
    it "reads the groups of a one-pass pattern and of one the Pike VM reads" do
      PLACEHOLDER.search_groups("Hello {{ First_Name }}!") { |groups| groups[1]? }.should eq("First_Name")
      HOST_PORT.search_groups("example.com:8080") { |groups| {groups[1]?, groups.byte_begin(1)} }
        .should eq({"8080", 12})
    end

    it "returns nil when nothing matches" do
      HOST_PORT.search_groups("example.com") { |groups| groups[1]? }.should be_nil
    end
  end

  describe "#each_match" do
    it "iterates as String#scan does, stepping over a character after an empty match" do
      list_of_spans = [] of Mica::Regex::StaticSpan
      Mica::Regex.static("a*").each_match("baé") { |span| list_of_spans << span }
      list_of_spans.map { |span| {span.byte_begin, span.byte_end} }.should eq([{0, 0}, {1, 2}, {2, 2}, {4, 4}])
    end
  end

  it "allocates nothing per search" do
    haystack = "routes: 2026 example.com:8080 {{ name }} my-first-post"
    SLUG.search(haystack)
    before = GC.stats.total_bytes
    1_000.times do
      SLUG.search(haystack)
      ROUTE_ID.matches?(haystack)
      HOST_PORT.search_groups(haystack) { |groups| groups.byte_end(1) }
      PLACEHOLDER.search_groups(haystack) { |groups| groups.byte_begin(1) }
    end
    (GC.stats.total_bytes - before).should eq(0)
  end
end
