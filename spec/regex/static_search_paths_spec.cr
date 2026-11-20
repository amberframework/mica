require "../spec_helper"

# Milestone S2's static search paths: the literal prefilter with anchored
# candidate searches, and the bounded backtracker that reads groups (and
# finds a match's start) where the one-pass DFA cannot. Each must give the
# runtime engine's answers, stay linear, and allocate nothing.
private LITERAL_RUN  = Mica::Regex.static("abc[a-z]*Z")
private RARE_LITERAL = Mica::Regex.static("Sherlock Holmes")
private FOLDED       = Mica::Regex.static("Sherlock Holmes", ignore_case: true)
private TWO_LITERALS = Mica::Regex.static("foo|foobar")
private HOST_PORT    = Mica::Regex.static(".*:(\\d+)")
private LAST_DIGIT   = Mica::Regex.static("([a-z]*)[a-z]*(\\d)")
private ALTERNATING  = Mica::Regex.static("((?:ab|a)*)(c)")
private WORDY_NUMBER = Mica::Regex.static("([a-z]+)-(\\d+)")
private LIMITS       = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def runtime(source : String, options = Mica::Regex::CompileOptions::None) : Mica::Regex::Expression
  Mica::Regex.compile(source, dialect: :crystal, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN,
    options: options)
end

# A budget of *per_byte* operations per haystack byte and nothing more.
private def per_byte(per_byte : Int64) : Mica::Regex::SearchLimits
  Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX // 4, work_per_byte: per_byte, work_per_state: 0_i64,
    base_work: 64_i64)
end

# Every group span of *pattern*'s first match from *offset*, or nil.
private def static_groups(pattern, haystack : String, offset : Int32 = 0) : Array(Mica::Regex::Span?)?
  pattern.search_groups(haystack, offset, limits: LIMITS) do |groups|
    Array(Mica::Regex::Span?).new(groups.size) { |group| groups.span?(group) }
  end
end

private def runtime_groups(expression : Mica::Regex::Expression, haystack : String, offset : Int32 = 0) : Array(Mica::Regex::Span?)?
  expression.search_groups(haystack, offset, limits: LIMITS) do |groups|
    Array(Mica::Regex::Span?).new(groups.size) { |group| groups.span?(group) }
  end
end

describe "Mica::Regex.static search paths" do
  describe "the literal prefilter" do
    it "finds the runtime engine's matches at prefilter candidates" do
      {
        {RARE_LITERAL, "Sherlock Holmes", Mica::Regex::CompileOptions::None},
        {FOLDED, "Sherlock Holmes", Mica::Regex::CompileOptions::IgnoreCase},
        {TWO_LITERALS, "foo|foobar", Mica::Regex::CompileOptions::None},
        {LITERAL_RUN, "abc[a-z]*Z", Mica::Regex::CompileOptions::None},
      }.each do |pattern, source, options|
        expression = runtime(source, options)
        {"", "Sherlock", "x sherlock HOLMES y Sherlock Holmes", "foobar foo", "abcabcZ abcdefZ abc",
         "é" * 40 + "SHERLOCK holmes" + "abcxyzZ"}.each do |haystack|
          (0..haystack.bytesize).each do |offset|
            next if offset < haystack.bytesize && haystack.byte_at(offset) & 0xC0 == 0x80
            expected = expression.search_span(haystack, offset, limits: LIMITS)
            {source, haystack, offset, pattern.search_span(haystack, offset, limits: LIMITS)}
              .should eq({source, haystack, offset, expected})
            pattern.matches?(haystack, offset, limits: LIMITS).should eq(!expected.nil?)
          end
        end
      end
    end

    it "takes the leftmost literal by priority when the literals are the whole matches" do
      TWO_LITERALS.search_span("xx foobar").should eq(Mica::Regex::Span.new(3, 6))
    end

    it "stays linear when the anchored tries keep failing" do
      # Every "abc" is a candidate whose try reads the letters to the end
      # without finding Z: without a cap the tries would read the haystack
      # once per candidate. The failed tries hand the search to the DFAs
      # once they read more than the haystack.
      haystack = "abc" * 30_000
      LITERAL_RUN.search_span(haystack, limits: per_byte(8)).should be_nil
      LITERAL_RUN.matches?(haystack, limits: per_byte(8)).should be_false
      (haystack + "Z").bytesize.should eq(90_001)
      LITERAL_RUN.search_span(haystack + "Z", limits: per_byte(8)).should eq(Mica::Regex::Span.new(0, 90_001))
    end

    it "allocates nothing" do
      haystack = "x sherlock HOLMES y " * 50
      FOLDED.search_span(haystack)
      before = GC.stats.total_bytes
      100.times { FOLDED.search_span(haystack, 7) }
      (GC.stats.total_bytes - before).should eq(0)
    end
  end

  describe "the bounded backtracker" do
    it "reads the runtime engine's groups on patterns that are not one-pass, whatever the span" do
      {
        {HOST_PORT, ".*:(\\d+)"},
        {LAST_DIGIT, "([a-z]*)[a-z]*(\\d)"},
        {ALTERNATING, "((?:ab|a)*)(c)"},
        {WORDY_NUMBER, "([a-z]+)-(\\d+)"},
      }.each do |pattern, source|
        expression = runtime(source)
        {1, 10, 100, 600, 3_000}.each do |length|
          {"example.com:" + "4" * length, "x" * length + ":12\nhost:80", "ab" * length + "c", "q" * length + "7",
           "a" * length + "b-12 word-345", "é" + "ab" * length + "c"}.each do |haystack|
            {0, 1, haystack.bytesize // 2}.each do |offset|
              next if offset < haystack.bytesize && haystack.byte_at(offset) & 0xC0 == 0x80
              {source, haystack.bytesize, offset, static_groups(pattern, haystack, offset)}
                .should eq({source, haystack.bytesize, offset, runtime_groups(expression, haystack, offset)})
            end
          end
        end
      end
    end

    it "charges its work to the budget" do
      error = expect_raises(Mica::Regex::SearchLimitError) do
        HOST_PORT.search_groups("x" * 50 + ":12", limits: per_byte(1)) { |groups| groups.byte_end(1) }
      end
      error.limit_name.should eq("max_work")
    end

    it "allocates nothing" do
      haystack = "example.com:8080"
      HOST_PORT.search_groups(haystack) { |groups| groups.byte_end(1) }
      before = GC.stats.total_bytes
      100.times { HOST_PORT.search_groups(haystack) { |groups| groups.byte_end(1) } }
      (GC.stats.total_bytes - before).should eq(0)
    end
  end
end
