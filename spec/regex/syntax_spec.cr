require "../spec_helper"

# Unit specs for the Mica::Regex R1 front end: the Crystal-dialect parser,
# class lowering and case folding, the size preflight, the allocation
# ledger and the Hir translation. The PCRE2 corpus census lives in
# pcre2_syntax_census_spec.cr.

private TRUSTED   = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private UNTRUSTED = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN

# The Hir of *pattern* in the Crystal dialect, as its s-expression.
private def hir_of(pattern : String, options = Mica::Regex::CompileOptions::None) : String
  Mica::Regex::Syntax.translate(pattern, dialect: :crystal, compile_limits: TRUSTED, options: options).root.to_s
end

# The error *pattern* raises, or nil.
private def error_of(pattern : String | Bytes, limits = TRUSTED, options = Mica::Regex::CompileOptions::None) : Mica::Error?
  Mica::Regex::Syntax.error?(pattern, dialect: :crystal, compile_limits: limits, options: options)
end

private def unsupported(pattern : String) : Mica::Regex::UnsupportedConstructError
  error = error_of(pattern)
  error.should be_a(Mica::Regex::UnsupportedConstructError)
  error.as(Mica::Regex::UnsupportedConstructError)
end

private def syntax_error(pattern : String) : Mica::Regex::SyntaxError
  error = error_of(pattern)
  unless error.is_a?(Mica::Regex::SyntaxError) && !error.is_a?(Mica::Regex::UnsupportedConstructError)
    fail "expected a SyntaxError for #{pattern.inspect}, got #{error.inspect}"
  end
  error
end

describe Mica::Regex::Syntax do
  describe "literals and escapes" do
    it_satisfies "REGEX-R1-literals", "reads plain and escaped literals" do
      hir_of("abc").should eq("(cat a b c)")
      hir_of("\\a\\e\\f\\n\\r\\t").should eq("(cat \\x{7} \\x{1B} \\x{C} \\x{A} \\x{D} \\x{9})")
      hir_of("\\x41\\x{1F600}\\o{101}\\101\\0").should eq("(cat A \\x{1F600} A A \\x{0})")
      hir_of("\\cA\\c?").should eq("(cat \\x{1} \\x{7F})")
      hir_of("\\N{U+263A}").should eq("\\x{263A}")
      hir_of("\\Qa.b*\\E+").should eq("(cat a . b *{1,})")
      hir_of("\\.\\\\").should eq("(cat . \\x{5C})")
      hir_of("é").should eq("\\x{E9}")
    end

    it_satisfies "REGEX-R1-literals", "reads numbers after a backslash as octal when no group can match" do
      hir_of("\\12").should eq("\\x{A}")
      unsupported("(a)\\1").construct.should eq("a backreference")
      unsupported("\\8").construct.should eq("a backreference")
    end

    it_satisfies "REGEX-R1-errors", "rejects malformed escapes with PCRE2's offsets" do
      syntax_error("\\").byte_offset.should eq(1)
      syntax_error("\\x{110000}").detail.should contain("too large")
      syntax_error("\\x{d800}").detail.should contain("disallowed Unicode code point")
      syntax_error("\\x{41").detail.should contain("closing brace missing")
      syntax_error("\\o").detail.should contain("missing opening brace")
      syntax_error("\\c").detail.should contain("\\c at end")
      syntax_error("\\c\u{E9}").detail.should contain("printable ASCII")
      syntax_error("\\q").detail.should contain("unrecognized character follows")
      syntax_error("\\u0041").detail.should contain("does not support")
      syntax_error("\\g").detail.should contain("\\g is not followed")
    end
  end

  describe "classes" do
    it_satisfies "REGEX-R1-classes", "reads ranges, negation and literal edge characters" do
      hir_of("[a-c]").should eq("[a-c]")
      hir_of("[^a]").should eq("[\\x{0}-\\x{60}b-\\x{10FFFF}]")
      hir_of("[]a]").should eq("[\\x{5D}a]")
      hir_of("[a-]").should eq("[\\x{2D}a]")
      hir_of("[\\d-]").should contain("\\x{2D}")
      hir_of("[\\Q]\\E]").should eq("[\\x{5D}]")
    end

    it_satisfies "REGEX-R1-classes", "lowers POSIX classes to Unicode sets in UCP mode and ASCII under (?aP)" do
      hir_of("[[:digit:]]").should eq(hir_of("\\p{Nd}"))
      hir_of("(?aP)[[:digit:]]").should eq("[0-9]")
      hir_of("(?aP)[[:^digit:]]").should eq("[\\x{0}-\\x{2F}\\x{3A}-\\x{10FFFF}]")
      hir_of("(?aD)\\d").should eq("[0-9]")
      hir_of("(?aW)\\w").should eq("[0-9A-Z\\x{5F}a-z]")
    end

    it_satisfies "REGEX-R1-errors", "rejects malformed classes" do
      syntax_error("[a").detail.should contain("missing terminating ]")
      syntax_error("[z-a]").detail.should contain("range out of order")
      syntax_error("[\\d-a]").detail.should contain("invalid range")
      syntax_error("[[:foo:]]").detail.should contain("unknown POSIX class name")
      syntax_error("[:alpha:]").detail.should contain("only within a class")
      syntax_error("[\\B]").detail.should contain("invalid in character class")
    end
  end

  describe "properties" do
    it_satisfies "REGEX-R1-properties", "accepts loose property names and negation" do
      hir_of("\\p{Lu}").should eq(hir_of("\\p{ L_u }"))
      hir_of("\\p{^Lu}").should eq(hir_of("\\P{Lu}"))
      hir_of("\\p{Greek}").should eq(hir_of("\\p{scx:Grek}"))
      hir_of("\\p{sc:Greek}").should_not eq(hir_of("\\p{scx:Greek}"))
      hir_of("\\p{Any}").should eq("[\\x{0}-\\x{10FFFF}]")
      hir_of("\\p{bidiclass:al}").should_not be_empty
      hir_of("\\p{Alphabetic}").should_not be_empty
      syntax_error("\\p{NotAProperty}").detail.should contain("unknown property")
      syntax_error("\\p").detail.should contain("malformed")
    end
  end

  describe "quantifiers" do
    it_satisfies "REGEX-R1-quantifiers", "reads every quantifier form" do
      hir_of("a*b+c?").should eq("(cat a{0,} b{1,} c{0,1})")
      hir_of("a{2}b{2,}c{2,3}d{,3}").should eq("(cat a{2,2} b{2,} c{2,3} d{0,3})")
      hir_of("a{ 2 , 3 }").should eq("a{2,3}")
      hir_of("a*?").should eq("a{0,}?")
      hir_of("(?U)a*").should eq("a{0,}?")
      hir_of("(?U)a*?").should eq("a{0,}")
      hir_of("a{x}").should eq("(cat a \\x{7B} x \\x{7D})")
      hir_of("a{,}").should eq("(cat a \\x{7B} , \\x{7D})")
    end

    it_satisfies "REGEX-R1-errors", "rejects quantifiers with nothing to repeat and bad counts" do
      syntax_error("*a").detail.should contain("quantifier does not follow a repeatable item")
      syntax_error("a**").byte_offset.should eq(3)
      syntax_error("^*").byte_offset.should eq(2)
      syntax_error("a{3,2}").detail.should contain("out of order")
      syntax_error("a{65536}").detail.should contain("too big")
    end
  end

  describe "groups" do
    it_satisfies "REGEX-R1-groups", "numbers capturing, named and branch-reset groups" do
      hir_of("(a)(?:b)(?<x>c)").should eq("(cat (cap 1 a) b (cap 2 x c))")
      hir_of("(?|(a)|(b)(c))(d)").should eq("(cat (alt (cap 1 a) (cat (cap 1 b) (cap 2 c))) (cap 3 d))")
      report = Mica::Regex::Syntax.check("(?<year>\\d{4})-(?'month'\\d\\d)(?P<day>\\d\\d)", dialect: :crystal, compile_limits: TRUSTED)
      report.capture_count.should eq(3)
      report.list_of_group_names.map(&.group_name).should eq(["year", "month", "day"])
      hir_of("(?n)(a)(?<b>c)").should eq("(cat a (cap 1 b c))")
    end

    it_satisfies "REGEX-R1-errors", "rejects unbalanced parentheses and bad names" do
      syntax_error("(a").detail.should contain("missing closing parenthesis")
      syntax_error("a)").detail.should contain("unmatched closing parenthesis")
      syntax_error("(?<1a>x)").detail.should contain("must start with a non-digit")
      syntax_error("(?<a>x)(?-J:(?<a>y))").detail.should contain("same name")
      error_of("(?<a>x)|(?<a>y)").should be_nil
      syntax_error("(?|(?<a>x)|(?<b>y))").detail.should contain("different names")
      error_of("(?|(?<a>a)(?<b>b)|(c)(?<a>d))").should be_nil
      error_of("(?<a>x)(?<a>y)(?<a>z)").should be_nil
      Mica::Regex::Syntax.check("(?|(?<a>x)|(?<a>y))(?<a>z)", dialect: :crystal, compile_limits: TRUSTED)
        .list_of_group_names.map { |entry| {entry.group_name, entry.capture_index} }.should eq([{"a", 1}, {"a", 2}])
      syntax_error("(?z)").detail.should contain("unrecognized character after (?")
    end
  end

  describe "options" do
    it_satisfies "REGEX-R1-options", "scopes inline options to their group and across alternatives" do
      hir_of("(?i:a)a").should eq("(cat [Aa] a)")
      hir_of("(a(?i)b|c)d").should eq("(cat (cap 1 (alt (cat a [Bb]) [Cc])) d)")
      hir_of("(?x) a b # comment\n c").should eq("(cat a b c)")
      hir_of("(?s).").should eq("[\\x{0}-\\x{10FFFF}]")
      hir_of(".").should eq("[\\x{0}-\\x{9}\\x{B}-\\x{10FFFF}]")
      hir_of("(?m)^$").should eq("(cat (look start_of_line) (look end_of_line))")
      hir_of("^$").should eq("(cat (look start_of_text) (look end_of_text_or_final_newline))")
      hir_of("(*UTF)(*UCP)(*LIMIT_MATCH=10)a").should eq("a")
      hir_of("(*BSR_ANYCRLF)\\R").should eq("(linebreak anycrlf)")
    end

    it_satisfies "REGEX-R1-excluded", "refuses newline conventions it cannot honor" do
      unsupported("(*CRLF)a").construct.should contain("newline convention")
      unsupported("(*NOTEMPTY)a").construct.should contain("NOTEMPTY")
    end
  end

  describe "excluded constructs" do
    {
      "a(?=b)"        => {"lookahead", 1},
      "a(?!b)"        => {"lookahead", 1},
      "(?<=a)b"       => {"lookbehind", 0},
      "(?<!a)b"       => {"lookbehind", 0},
      "(?>a)"         => {"an atomic group", 0},
      "a++"           => {"a possessive quantifier", 2},
      "(a)\\1"        => {"a backreference", 3},
      "(?<n>a)\\k<n>" => {"a backreference", 7},
      "(?R)"          => {"recursion or a subroutine call", 0},
      "(a)(?1)"       => {"recursion or a subroutine call", 3},
      "(?(1)a|b)"     => {"a conditional group", 0},
      "(?C1)"         => {"a callout", 0},
      "(*FAIL)"       => {"a backtracking verb (*FAIL)", 0},
      "a\\Kb"         => {"\\K (reset the match start)", 1},
      "\\C"           => {"\\C (one code unit)", 0},
      "\\X"           => {"\\X (an extended grapheme cluster, until milestone R9)", 0},
      "(*pla:a)"      => {"lookahead", 0},
    }.each do |pattern, expected|
      it_satisfies "REGEX-R1-excluded", "names #{expected[0]} in #{pattern.inspect} at byte #{expected[1]}" do
        error = unsupported(pattern)
        error.construct.should eq(expected[0])
        error.byte_offset.should eq(expected[1])
        error.message.to_s.should contain("outside the Mica::Regex dialect")
      end
    end
  end

  describe "case folding" do
    it_satisfies "REGEX-R1-case-folding", "closes literals and ranges over simple case folding orbits" do
      hir_of("(?i)k").should eq("[Kk\\x{212A}]")
      hir_of("(?i)s").should eq("[Ss\\x{17F}]")
      hir_of("(?i)[a-b]").should eq("[ABab]")
      hir_of("(?i)[^k]").should_not contain("212A")
    end

    it_satisfies "REGEX-R1-case-folding", "keeps ASCII and non-ASCII apart under (?r)" do
      hir_of("(?ir)k").should eq("[Kk]")
      hir_of("(?ir)\\x{212A}").should eq("\\x{212A}")
    end

    it_satisfies "REGEX-R1-case-folding", "leaves escapes unfolded except cased-letter categories, as PCRE2 does" do
      hir_of("(?i)\\p{Lu}").should eq(hir_of("\\p{L&}"))
      hir_of("(?i)[[:upper:]]").should eq(hir_of("\\p{Lu}"))
      hir_of("(?i)\\d").should eq(hir_of("\\d"))
    end

    it_satisfies "REGEX-R1-case-folding", "folds every class member in the ECMA-262 dialect" do
      char_class = Mica::Regex::Ast::CharClass.new(0,
        [Mica::Regex::Ast::ClassItem.ascii(Mica::Regex::Ast::AsciiSet::Word, false)], false,
        Mica::Regex::CompileOptions::IgnoreCase)
      ledger = Mica::Regex::AllocationLedger.new(TRUSTED.max_compile_bytes)
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
      ecma = Mica::Regex::ClassLowering.lower(char_class, :ecma262, TRUSTED, ledger, meter)
      crystal = Mica::Regex::ClassLowering.lower(char_class, :crystal, TRUSTED, ledger, meter)
      ecma.includes?(0x017F).should be_true
      ecma.includes?(0x212A).should be_true
      crystal.includes?(0x212A).should be_false
    end
  end

  describe "Hir" do
    it_satisfies "REGEX-R1-hir", "drops non-capturing groups and keeps repetition counts" do
      hir_of("(?:ab)+").should eq("(cat a b){1,}")
      hir_of("a|b|").should eq("(alt a b (empty))")
      hir_of("\\bx\\B").should eq("(cat (look word_boundary) x (look not_word_boundary))")
      hir_of("[[:<:]]").should eq("(look word_start)")
    end
  end

  describe "limits" do
    it_satisfies "REGEX-R1-limits", "refuses patterns longer than max_pattern_bytes" do
      error = error_of("a" * 4097, UNTRUSTED)
      error.should be_a(Mica::Regex::CompileLimitError)
      error.as(Mica::Regex::CompileLimitError).limit_name.should eq("max_pattern_bytes")
    end

    it_satisfies "REGEX-R1-limits", "refuses nesting deeper than max_nest_depth" do
      limits = Mica::Regex::CompileLimits.custom(max_nest_depth: 3)
      error_of("(((a)))", limits).should be_nil
      error = error_of("((((a))))", limits).as(Mica::Regex::CompileLimitError)
      error.limit_name.should eq("max_nest_depth")
      error.byte_offset.should eq(3)
    end

    it_satisfies "REGEX-R1-limits", "refuses more captures than max_captures" do
      limits = Mica::Regex::CompileLimits.custom(max_captures: 2)
      error_of("(a)(b)", limits).should be_nil
      error_of("(a)(b)(c)", limits).as(Mica::Regex::CompileLimitError).limit_name.should eq("max_captures")
    end

    it_satisfies "REGEX-R1-limits", "refuses classes with more ranges than max_class_ranges" do
      limits = Mica::Regex::CompileLimits.custom(max_class_ranges: 10)
      error_of("[a-e]", limits).should be_nil
      error_of("\\p{L}", limits).as(Mica::Regex::CompileLimitError).limit_name.should eq("max_class_ranges")
    end

    it_satisfies "REGEX-R1-limits", "holds case-folded literals to max_class_ranges like classes" do
      # (?i)k stands for [Kk\x{212A}]: three ranges.
      [1, 2].each do |max_class_ranges|
        limits = Mica::Regex::CompileLimits.custom(max_class_ranges: max_class_ranges)
        error_of("(?i)k", limits).as(Mica::Regex::CompileLimitError).limit_name.should eq("max_class_ranges")
        error_of("(?i)[k]", limits).as(Mica::Regex::CompileLimitError).limit_name.should eq("max_class_ranges")
      end
      error_of("(?i)k", Mica::Regex::CompileLimits.custom(max_class_ranges: 3)).should be_nil
    end

    it_satisfies "REGEX-R1-preflight", "refuses nested counted repetitions before expanding them" do
      error = error_of("((a{100}){100}){100}", UNTRUSTED).as(Mica::Regex::CompileLimitError)
      error.limit_name.should eq("max_program_states")
      error_of("(a{1000}){1000}", UNTRUSTED).as(Mica::Regex::CompileLimitError).limit_name.should eq("max_program_states")
      error_of("(?:a{1000}){0}", UNTRUSTED).should be_nil
    end

    it_satisfies "REGEX-R1-preflight", "uses saturating arithmetic" do
      Mica::Regex::Preflight.multiply(Int64::MAX // 2, 3_i64).should eq(Int64::MAX)
      Mica::Regex::Preflight.add(Int64::MAX, 1_i64).should eq(Int64::MAX)
      error_of("(((((a{65535}){65535}){65535}){65535}){65535})", TRUSTED).should be_a(Mica::Regex::CompileLimitError)
    end

    it_satisfies "REGEX-R1-preflight", "counts class states from exact UTF-8 sequences" do
      Mica::Regex::Preflight.set_states(Mica::Regex::CodePointSet.new([{0x61, 0x7A}])).should eq(1)
      Mica::Regex::Preflight.set_states(Mica::Regex::CodePointSet.new([{0x00, 0x7F}, {0xE9, 0xE9}])).should eq(1 + 2 + 1)
    end

    it_satisfies "REGEX-R1-ledger", "refuses compiles that would pass max_compile_bytes" do
      limits = Mica::Regex::CompileLimits.custom(max_compile_bytes: 2_000_i64)
      error = error_of("a" * 500, limits).as(Mica::Regex::CompileLimitError)
      error.limit_name.should eq("max_compile_bytes")
      report = Mica::Regex::Syntax.check("abc", dialect: :crystal, compile_limits: TRUSTED)
      report.compile_bytes.should be > 0
      report.compile_bytes.should be <= TRUSTED.max_compile_bytes
    end

    it_satisfies "REGEX-R1-limits", "applies the work budget of a caller's meter" do
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 1, base_operations: 10))
      expect_raises(Mica::WorkBudgetExceededError) do
        Mica::Regex::Syntax.check("\\p{L}\\p{L}", dialect: :crystal, compile_limits: TRUSTED, meter: meter)
      end
    end
  end

  describe "UTF-8 sequences" do
    it_satisfies "REGEX-R1-utf8-sequences", "splits ranges exactly and skips surrogates" do
      list_of_sequences = [] of {Int32, Int32, Int32}
      Mica::Regex::Utf8Sequences.each(0, 0x10FFFF) { |length, first, last| list_of_sequences << {length, first, last} }
      covered = list_of_sequences.sum { |_length, first, last| (last - first + 1).to_i64 }
      covered.should eq(0x110000 - 0x800)
      list_of_sequences.none? { |_length, first, last| first <= 0xDFFF && last >= 0xD800 }.should be_true
      list_of_sequences.each do |length, first, last|
        Mica::Regex::Utf8Sequences.encoded_length(first).should eq(length)
        Mica::Regex::Utf8Sequences.encoded_length(last).should eq(length)
      end
      Mica::Regex::Utf8Sequences.count(0x00, 0x7F).should eq({1, 1})
    end
  end

  describe "dialects" do
    it "reports the milestone for dialects whose parser is not built yet" do
      expect_raises(ArgumentError, /R6/) do
        Mica::Regex::Syntax.check("a", dialect: :ecma262, compile_limits: TRUSTED)
      end
    end
  end

  it_satisfies "REGEX-R1-errors", "rejects invalid UTF-8 in the pattern" do
    error = error_of(Bytes[0x61, 0xFF])
    error.should be_a(Mica::Regex::SyntaxError)
    error.as(Mica::Regex::SyntaxError).byte_offset.should eq(1)
  end
end
