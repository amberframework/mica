require "../spec_helper"

private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::REQUEST

private def expression(source : String, options = Mica::Regex::CompileOptions::None) : Mica::Regex::Expression
  Mica::Regex::Expression.new(source, options, compile_limits: TRUSTED)
end

private def groups(source : String, haystack : String, options = Mica::Regex::CompileOptions::None) : Array(String?)?
  expression(source, options).match(haystack, limits: LIMITS).try(&.to_a)
end

describe Mica::Regex::Expression do
  describe "matching" do
    it_satisfies "REGEX-R2-api", "finds the leftmost-first match with its captures" do
      groups("(a|ab)(c|bcd)(d*)", "abcd").should eq(["abcd", "a", "bcd", ""])
      groups("a+", "baaa").should eq(["aaa"])
      groups("(?<year>\\d{4})-(\\d\\d)", "on 2026-11").should eq(["2026-11", "2026", "11"])
      groups("x", "abc").should be_nil
      groups("", "abc").should eq([""])
    end

    it_satisfies "REGEX-R2-semantics", "ends a group repetition after an empty iteration, as PCRE2 does" do
      groups("(a|)*", "").should eq(["", ""])
      groups("(a*)*", "b").should eq(["", ""])
      groups("(a*)+", "b").should eq(["", ""])
      groups("(a*|b)*", "ab").should eq(["a", ""])
      groups("((a)|b)+", "ab").should eq(["ab", "b", "a"])
    end

    it_satisfies "REGEX-R2-semantics", "keeps \\R atomic: a later failure never splits \\r\\n" do
      groups("\\R\\n", "\r\n").should be_nil
      groups("\\R", "\r\n").should eq(["\r\n"])
      groups("a\\Rb", "a\rb").should eq(["a\rb"])
      groups("\\R", " ").should eq([" "])
    end

    it_satisfies "REGEX-R2-semantics", "gives anchors and word boundaries PCRE2's meanings" do
      groups("x$", "x\n").should eq(["x"])
      groups("x$", "x\n", Mica::Regex::CompileOptions::DollarEndOnly).should be_nil
      groups("^b", "a\nb").should be_nil
      groups("(?m)^b", "a\nb").should eq(["b"])
      expression("(?m)^", Mica::Regex::CompileOptions::None).scan("a\n", limits: LIMITS).map(&.byte_begin).should eq([0])
      groups("\\bfoo\\b", "a foo b").should eq(["foo"])
      groups("\\bé", "café").should be_nil
      groups("(?aW)\\bé", "café").should eq(["é"])
      groups("\\Gb", "ab").should be_nil
    end

    it_satisfies "REGEX-R2-semantics", "matches whole characters through UTF-8 automata, with case folding" do
      groups("[^a]", "ä").should eq(["ä"])
      groups("(?i)k", "K").should eq(["K"])
      groups("\\p{Greek}+", "abc αβγ").should eq(["αβγ"])
      groups(".", "😀").should eq(["😀"])
      groups("é|e", "café").should eq(["é"])
    end

    it_satisfies "REGEX-R2-api", "honors Anchored, EndAnchored and FirstLine" do
      anchored = Mica::Regex::MatchOptions::Anchored
      expression("b").match("ab", 0, anchored, limits: LIMITS).should be_nil
      expression("b").match("ab", 1, anchored, limits: LIMITS).try(&.[0]).should eq("b")
      expression("a", Mica::Regex::CompileOptions::EndAnchored).match("aba", limits: LIMITS).try(&.byte_begin).should eq(2)
      first_line = Mica::Regex::CompileOptions::FirstLine
      expression("b", first_line).match("a\nb", limits: LIMITS).should be_nil
      expression("\\nb", first_line).match("a\nb", limits: LIMITS).try(&.[0]).should eq("\nb")
    end

    it_satisfies "REGEX-R2-api", "matches? and match agree, and match! raises MatchNotFoundError" do
      expression("b+").matches?("abbb", limits: LIMITS).should be_true
      expression("c").matches?("abbb", limits: LIMITS).should be_false
      expect_raises(Mica::Regex::MatchNotFoundError) { expression("c").match!("ab", limits: LIMITS) }
    end

    it_satisfies "REGEX-R2-api", "takes character positions in match and byte indexes in match_at_byte_index" do
      compiled = expression("b")
      compiled.match("ébéb", 2, limits: LIMITS).try(&.byte_begin).should eq(5)
      compiled.match_at_byte_index("ébéb", 3, limits: LIMITS).try(&.byte_begin).should eq(5)
      compiled.match("ab", 5, limits: LIMITS).should be_nil
      compiled.match_at_byte_index("ab", 9, limits: LIMITS).should be_nil
      expect_raises(ArgumentError, "inside a UTF-8 character") { compiled.match_at_byte_index("éb", 1, limits: LIMITS) }
      expect_raises(ArgumentError, "Negative byte index") { compiled.match_at_byte_index("éb", -1, limits: LIMITS) }
    end

    it_satisfies "REGEX-R2-api", "refuses a haystack that is not valid UTF-8 with Mica::EncodingError" do
      error = expect_raises(Mica::EncodingError) { expression("a").match(String.new(Bytes[0x61, 0xFF]), limits: LIMITS) }
      error.byte_offset.should eq(1)
    end

    it_satisfies "REGEX-R2-api", "leaves the invalid-UTF mode to milestone R4" do
      expect_raises(ArgumentError, "R4") { expression("a", Mica::Regex::CompileOptions::MatchInvalidUtf) }
    end
  end

  describe "MatchData" do
    it_satisfies "REGEX-R2-api", "follows Regex::MatchData for groups that did not take part and empty groups" do
      match = expression("(a)(x)?()").match!("ab", limits: LIMITS)
      match.size.should eq(4)
      match.group_size.should eq(3)
      match[1].should eq("a")
      match[2]?.should be_nil
      match[3].should eq("")
      match[-1].should eq("")
      expect_raises(IndexError, "Capture group 2 was not matched") { match[2] }
      expect_raises(IndexError, "Invalid capture group index: 4") { match[4] }
      match[9]?.should be_nil
      match.captures.should eq(["a", nil, ""])
      match.to_a.should eq(["a", "a", nil, ""])
      match[0..1].should eq(["a", "a"])
      match.pre_match.should eq("")
      match.post_match.should eq("b")
    end

    it_satisfies "REGEX-R2-api", "reports byte and character offsets" do
      match = expression("(b+)").match!("ééxbb!", limits: LIMITS)
      match.byte_begin(1).should eq(5)
      match.byte_end(1).should eq(7)
      match.begin(1).should eq(3)
      match.end(1).should eq(5)
    end

    it_satisfies "REGEX-R2-api", "selects duplicate named groups as stdlib's PCRE2 binding does" do
      compiled = expression("(?|(?<n>a)|(?<n>b))(?<n>c)?")
      compiled.list_of_name_entries.map { |entry| {entry.group_name, entry.capture_index} }.should eq([{"n", 1}, {"n", 2}])
      compiled.match!("bc", limits: LIMITS)["n"].should eq("c")
      compiled.match!("a", limits: LIMITS)["n"].should eq("a")
      dup = expression("(?<n>a)|(?<n>b)")
      dup.match!("b", limits: LIMITS)["n"].should eq("b")
      expect_raises(KeyError, "does not exist") { dup.match!("b", limits: LIMITS)["zz"] }
      expression("(?<x>a)?b").match!("b", limits: LIMITS)["x"]?.should be_nil
      expect_raises(KeyError, "was not matched") { expression("(?<x>a)?b").match!("b", limits: LIMITS)["x"] }
    end

    it_satisfies "REGEX-R2-api", "orders the name table by name and lists named captures" do
      compiled = expression("(?<zeta>z)(?<alpha>a)(b)")
      compiled.name_table.should eq({2 => "alpha", 1 => "zeta"})
      compiled.name_table.keys.should eq([2, 1])
      match = compiled.match!("zab", limits: LIMITS)
      match.named_captures.should eq({"zeta" => "z", "alpha" => "a"})
      match.captures.should eq(["b"])
      match.to_h.should eq({0 => "zab", "zeta" => "z", "alpha" => "a", 3 => "b"})
    end
  end

  describe "iteration" do
    it_satisfies "REGEX-R2-iteration", "scans like String#scan, advancing a character after an empty match" do
      expression("a*").scan("baaé", limits: LIMITS).map { |match| {match.byte_begin, match.byte_end} }
        .should eq([{0, 0}, {1, 3}, {3, 3}, {5, 5}])
      words = [] of String
      expression("\\w+").scan("one two", limits: LIMITS) { |match| words << match[0] }.should eq("one two")
      words.should eq(["one", "two"])
    end

    it_satisfies "REGEX-R2-iteration", "replaces like String#gsub and String#sub" do
      compiled = expression("(\\w+)@(\\w+)")
      compiled.gsub("x a@b c@d", "<\\2 at \\1>", limits: LIMITS).should eq("x <b at a> <d at c>")
      compiled.gsub("x a@b", "\\\\0", limits: LIMITS).should eq("x \\0")
      compiled.gsub("x a@b", "\\0", false, limits: LIMITS).should eq("x \\0")
      compiled.sub("a@b c@d", "-", limits: LIMITS).should eq("- c@d")
      compiled.gsub("a@b c@d", limits: LIMITS) { |text, match| text.upcase + match[2] }.should eq("A@Bb C@Dd")
      expression("").gsub("abc", "-", limits: LIMITS).should eq("-a-b-c-")
      expression("x*").gsub("abxc", "-", limits: LIMITS).should eq("-a-b--c-")
      expression("\\b").gsub(" é", "|", limits: LIMITS).should eq(" |é|")
      expression("[ab]").gsub("cab", {"a" => "1", "b" => 2}, limits: LIMITS).should eq("c12")
      named = expression("(?<w>o+)")
      named.gsub("foo", "[\\k<w>]", limits: LIMITS).should eq("f[oo]")
      expect_raises(IndexError, "Undefined group name") { named.gsub("foo", "\\k<q>", limits: LIMITS) }
      expression("q").gsub("abc", "-", limits: LIMITS).should eq("abc")
    end

    it_satisfies "REGEX-R2-iteration", "splits like String#split, captures included" do
      expression(",\\s*").split("a, b,c", limits: LIMITS).should eq(["a", "b", "c"])
      expression("(-)").split("a-b-c", limits: LIMITS).should eq(["a", "-", "b", "-", "c"])
      expression("x*").split("axbc", limits: LIMITS).should eq(["a", "b", "c"])
      expression("").split("abc", 2, limits: LIMITS).should eq(["a", "bc"])
      expression(",").split(",a,,b,", remove_empty: true, limits: LIMITS).should eq(["a", "b"])
      expression(",").split("a,b,c", 2, limits: LIMITS).should eq(["a", "b,c"])
      expression(",").split("", limits: LIMITS).should eq([""])
    end
  end

  describe "limits" do
    it_satisfies "REGEX-R2-limits", "raises SearchLimitError naming max_work when a search runs out of work" do
      tight = Mica::Regex::SearchLimits.custom(work_ceiling: 10_000_i64)
      error = expect_raises(Mica::Regex::SearchLimitError) do
        # The haystack holds the c every match needs, so the search runs
        # rather than stopping at the required-byte check.
        expression("(a|aa)*c").match("a" * 5_000 + "c", limits: tight)
      end
      error.limit_name.should eq("max_work")
      error.limit_value.should eq(10_000)
      error.should be_a(Mica::LimitExceededError)
    end

    it_satisfies "REGEX-R2-limits", "counts an iteration call's searches against one allowance" do
      compiled = expression("[a-z]+X|[a-z]")
      haystack = "a" * 400
      single = Mica::Regex::SearchLimits.custom(work_ceiling: 40_000_i64)
      compiled.match(haystack, limits: single).should_not be_nil
      expect_raises(Mica::Regex::SearchLimitError, "max_work") { compiled.scan(haystack, limits: single) }
    end

    it_satisfies "REGEX-R2-limits", "raises SearchLimitError naming max_output_bytes for gsub, sub and split" do
      small = Mica::Regex::SearchLimits.custom(max_output_bytes: 10_i64)
      expect_raises(Mica::Regex::SearchLimitError, "max_output_bytes") do
        expression("a").gsub("aaaa", "bbbb", limits: small)
      end
      expect_raises(Mica::Regex::SearchLimitError, "max_output_bytes") do
        expression("x").sub("x" + "y" * 20, "z", limits: small)
      end
      expect_raises(Mica::Regex::SearchLimitError, "max_output_bytes") do
        expression(",").split("a" * 20, limits: small)
      end
      expression("a").gsub("aa", "bb", limits: small).should eq("bbbb")
    end

    it_satisfies "REGEX-R2-limits", "charges max_output_bytes before each replacement piece is written" do
      cap = 1_i64 * 1024 * 1024
      small = Mica::Regex::SearchLimits.custom(max_output_bytes: cap)
      haystack = "a" * (256 * 1024)
      compiled = expression("a")
      # Unbounded, each would build about 50 MiB. Bounded, the allocation is
      # the result buffer, which doubles up to just past the cap (at most
      # 1/4 + 1/2 + 1 + 2 times the cap), plus a few bytes per match.
      {"\\0" * 200, "\\k<x>" * 200}.each do |replacement|
        named = replacement.includes?("k<") ? expression("(?<x>a)") : compiled
        GC.collect
        before = allocated_bytes_so_far
        expect_raises(Mica::Regex::SearchLimitError, "max_output_bytes") do
          named.gsub(haystack, replacement, limits: small)
        end
        (allocated_bytes_so_far - before).should be < 4.5 * cap
      end
      GC.collect
      before = allocated_bytes_so_far
      expect_raises(Mica::Regex::SearchLimitError, "max_output_bytes") do
        compiled.gsub(haystack, limits: small) { |matched| matched * 200 }
      end
      (allocated_bytes_so_far - before).should be < 4.5 * cap
    end

    it_satisfies "REGEX-R2-limits", "meters split's shortcut paths like every other search" do
      no_work = Mica::Regex::SearchLimits.custom(work_ceiling: 0_i64)
      invalid = String.new(Bytes[0x61, 0x2C, 0xFF])
      {expression(""), expression(",")}.each do |compiled|
        limit = compiled.source.empty? ? nil : 1
        expect_raises(Mica::Regex::SearchLimitError, "max_work") do
          compiled.split("abc" * 1_000, limit, limits: no_work)
        end
        expect_raises(Mica::DeadlineExceededError) do
          compiled.split("abc" * 1_000, limit, limits: LIMITS, timeout: Time::Span.zero)
        end
        expect_raises(Mica::EncodingError) { compiled.split(invalid, limit, limits: LIMITS) }
      end
      # One operation per character, on top of validation.
      tight = Mica::Regex::SearchLimits.custom(work_ceiling: 4_500_i64)
      expect_raises(Mica::Regex::SearchLimitError, "max_work") { expression("").split("abc" * 1_000, limits: tight) }
      expression("").split("abc", limits: tight).should eq(["a", "b", "c"])
    end

    it_satisfies "REGEX-R2-limits", "reads the deadline at the start of every call, so a passed timeout fails a short search" do
      expect_raises(Mica::DeadlineExceededError) do
        expression("a").match("a", limits: LIMITS, timeout: Time::Span.zero)
      end
      expression("a").match("a", limits: LIMITS, timeout: 1.minute).should_not be_nil
    end

    it_satisfies "REGEX-R2-limits", "stops at a timeout with Mica::DeadlineExceededError" do
      compiled = expression("(?:a|b|ab|ba)*c")
      expect_raises(Mica::DeadlineExceededError) do
        compiled.scan("ab" * 200_000, limits: Mica::Regex::SearchLimits::TRUSTED_INPUT, timeout: Time::Span.zero)
      end
    end

    it_satisfies "REGEX-R2-limits", "refuses a program whose Pike VM workspace passes max_pike_bytes at compile time" do
      limits = Mica::Regex::CompileLimits.custom(max_pike_bytes: 4_096_i64)
      error = expect_raises(Mica::Regex::CompileLimitError) do
        Mica::Regex::Expression.new("(a)(b)(c)(d)(e)(f)(g)(h)", compile_limits: limits)
      end
      error.limit_name.should eq("max_pike_bytes")
      program = expression("(a)(b)(c)(d)(e)(f)(g)(h)").program
      Mica::Regex::Program.pike_workspace_bytes(program.state_count.to_i64, program.slot_count.to_i64)
        .should eq(16 * program.state_count * 18 + 32 * program.state_count + 8 * 18)
    end

    it "computes the documented work allowance" do
      Mica::Regex::SearchLimits::REQUEST.max_work(100, 0_i64).should eq(64 * 100 + 4_096)
      Mica::Regex::SearchLimits::REQUEST.max_work(100, 1_000_i64).should eq(64 * 100 + 4_096 + 4_096 * 1_000)
      Mica::Regex::SearchLimits::REQUEST.max_work(100, 1_000_000_000_i64).should eq(100_000_000)
    end
  end

  describe "the compiled program" do
    it_satisfies "REGEX-R2-compiler", "emits no more states than the size preflight bound" do
      ["a{2,5}", "(?i)straße", "\\p{L}+", "[^\\n]*", "\\R", "(a|b|)+?", "(?:x{3}){2,}", ".", "\\w{2}\\b", "(*BSR_ANYCRLF)\\R"].each do |source|
        report = Mica::Regex::Syntax.check(source, dialect: :crystal, compile_limits: TRUSTED)
        expression(source).program.state_count.should be <= report.state_estimate
      end
    end

    it_satisfies "REGEX-R2-compiler", "checks max_program_states while emitting and refuses compile bombs" do
      expect_raises(Mica::Regex::CompileLimitError, "max_program_states") do
        Mica::Regex::Expression.new("(a{1000}){1000}", compile_limits: TRUSTED)
      end
    end

    it_satisfies "REGEX-R2-api", "escapes, unions and prints like Regex" do
      Mica::Regex.escape("a.b*c").should eq("a\\.b\\*c")
      Mica::Regex.needs_escape?("a.b").should be_true
      source = Mica::Regex.union_source(["a.b", expression("c", Mica::Regex::CompileOptions::IgnoreCase)])
      source.should eq("a\\.b|(?i-mnrsxUa:c)")
      expression(source).matches?("xC", limits: LIMITS).should be_true
      Mica::Regex.compile("a", dialect: :crystal, compile_limits: TRUSTED).should eq(expression("a"))
    end
  end
end
