require "../spec_helper"

# Findings from the third review round of Mica::Regex R2.

private UNTRUSTED = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
private TRUSTED   = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS    = Mica::Regex::SearchLimits::TRUSTED_INPUT
private alias Option = Mica::Regex::CompileOptions

# What *expression* finds in each haystack, captures included.
private def results(expression : Mica::Regex::Expression, list_of_haystacks : Array(String)) : Array(Array(String?)?)
  list_of_haystacks.map { |haystack| expression.match(haystack, limits: LIMITS).try(&.to_a) }
end

# Bytes the collector hands out while the block runs: the least of three
# runs, so a stray allocation the runtime makes meanwhile (seen as a
# few KiB of noise inside the spec runner) does not count. Collection is
# off during each run, so no finalizer runs inside it either.
private def allocated_bytes(&) : Int64
  Array.new(3) do
    GC.collect
    GC.disable
    begin
      before = GC.stats.total_bytes
      yield
      (GC.stats.total_bytes - before).to_i64
    ensure
      GC.enable
    end
  end.min
end

# Each inline option with a pattern and haystacks on which it changes the
# result.
private INLINE_CASES = [
  {Option::IgnoreCase, "k", ["K", "k", "K"]},
  {Option::Multiline, "^b$", ["a\nb\nc"]},
  {Option::DotAll, "a.b", ["a\nb"]},
  {Option::Extended, "a b # comment", ["ab", "a b"]},
  {Option::None, "a\\Qb)", ["ab)", "ab"]},
  {Option::Extended, "(?-x)a# b", ["a# b", "ab"]},
  {Option::Extended | Option::ExtendedMore, "[a b]+", [" a", "ab "]},
  {Option::Ungreedy, "a+(b*?)", ["aaabbb"]},
  {Option::NoAutoCapture, "(a)(?<n>b)", ["ab"]},
  {Option::IgnoreCase | Option::CaselessRestrict, "k", ["K", "K"]},
  {Option::AsciiBackslashD, "\\d", ["٣", "3"]},
  {Option::AsciiBackslashS, "\\s", [" ", " "]},
  {Option::AsciiBackslashW, "\\w\\b", ["é", "e"]},
  {Option::AsciiPosix | Option::AsciiDigit, "[[:alpha:]][[:digit:]]", ["é٣", "e3"]},
  {Option::AsciiPosix, "[[:alpha:]][[:digit:]]", ["é٣", "e٣"]},
  {Option::AsciiDigit, "[[:alpha:]][[:digit:]]", ["é٣", "é3"]},
  {Option::ASCII_ALL, "\\w\\d\\s[[:alpha:]]", ["é٣ é", "a1 b"]},
  {Option::INLINE & ~Option::ExtendedMore, "(A) + \\w", ["aaé", "aa_"]},
]

describe "Mica::Regex R2 review round 3" do
  describe "union_source" do
    it_satisfies "REGEX-R2-api", "keeps every inline option of an Expression member" do
      INLINE_CASES.each do |(options, source, list_of_haystacks)|
        member = Mica::Regex::Expression.new(source, options, compile_limits: TRUSTED)
        union = Mica::Regex::Expression.new(Mica::Regex.union_source([member]), compile_limits: TRUSTED)
        results(union, list_of_haystacks).should eq(results(member, list_of_haystacks))
        # The member's options hold whatever options the union is compiled with.
        outer = Mica::Regex::Expression.new(Mica::Regex.union_source([member]), Option::INLINE, compile_limits: TRUSTED)
        results(outer, list_of_haystacks).map(&.try(&.first)).should eq(results(member, list_of_haystacks).map(&.try(&.first)))
      end
    end

    it_satisfies "REGEX-R2-api", "shows the option the review found lost: (?aW)\\w does not match é" do
      member = Mica::Regex::Expression.new("\\w", Option::AsciiBackslashW, compile_limits: TRUSTED)
      union = Mica::Regex::Expression.new(Mica::Regex.union_source([member]), compile_limits: TRUSTED)
      member.matches?("é", limits: LIMITS).should be_false
      union.matches?("é", limits: LIMITS).should be_false
    end

    it_satisfies "REGEX-R2-api", "refuses a member whose options have no inline form" do
      [Option::Anchored, Option::FirstLine, Option::DollarEndOnly, Option::EndAnchored].each do |options|
        member = Mica::Regex::Expression.new("a", options, compile_limits: TRUSTED)
        expect_raises(ArgumentError, /no inline form/) { Mica::Regex.union_source([member]) }
      end
    end
  end

  describe "the Pike VM memory bound" do
    it_satisfies "REGEX-R2-limits", "keeps one capture match within max_pike_bytes" do
      expression = Mica::Regex::Expression.new("\\A(a){14000}", compile_limits: UNTRUSTED)
      haystack = "a" * 14_000
      # The R2 path (Pike VM span pass, then the capture pass); the lazy-DFA
      # caches R3 adds are bounded by their CachePool (cache_pool_spec.cr).
      bytes = allocated_bytes do
        Mica::Regex::Searcher.new(expression.program, haystack, LIMITS, nil, Mica::Regex::Engine::TwoPhase)
          .find(0, Mica::Regex::MatchOptions::None, true).should_not be_nil
      end
      bytes.should be <= UNTRUSTED.max_pike_bytes
    end

    it_satisfies "REGEX-R2-compiler", "charges a capture-free program the 32·m span workspace" do
      expression = Mica::Regex::Expression.new("\\A(?:a{30000}){3}", compile_limits: UNTRUSTED)
      program = expression.program
      program.state_count.should be > 65_536
      expected = Mica::Regex::AllocationLedger.granules(32_i64 * program.state_count) +
                 Mica::Regex::AllocationLedger.granules(instance_sizeof(Mica::Regex::PikeVM))
      Mica::Regex::PikeVM.workspace_charge(program, captures: false).should eq(expected)
      haystack = "a" * 90_000
      bytes = allocated_bytes do
        Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, Mica::Regex::Engine::TwoPhase)
          .matches?(0, Mica::Regex::MatchOptions::None).should be_true
      end
      bytes.should be <= UNTRUSTED.max_pike_bytes
    end

    it_satisfies "REGEX-R2-compiler", "allocates no more than the calculated charge for a maximum-size workspace" do
      # The largest capture program UNTRUSTED_PATTERN accepts in this family.
      expression = Mica::Regex::Expression.new("\\A(a){14000}", compile_limits: UNTRUSTED)
      program = expression.program
      charge = Mica::Regex::PikeVM.workspace_charge(program, captures: true)
      charge.should be <= UNTRUSTED.max_pike_bytes
      allocated_bytes { Mica::Regex::PikeVM.new(program, captures: true) }.should be <= charge
      span = Mica::Regex::PikeVM.workspace_charge(program, captures: false)
      allocated_bytes { Mica::Regex::PikeVM.new(program, captures: false) }.should be <= span
    end

    it_satisfies "REGEX-R2-compiler", "refuses the over-cap negative control" do
      error = expect_raises(Mica::Regex::CompileLimitError) do
        Mica::Regex::Expression.new("\\A(a){15000}", compile_limits: UNTRUSTED)
      end
      error.limit_name.should eq("max_pike_bytes")
    end

    it_satisfies "REGEX-R2-limits", "keeps the backtracker inside what the workspace leaves of max_pike_bytes" do
      expression = Mica::Regex::Expression.new("(a|b)*c", compile_limits: UNTRUSTED)
      program = expression.program
      program.backtracker_allowance.should eq(UNTRUSTED.max_pike_bytes - Mica::Regex::PikeVM.workspace_charge(program, captures: true))
      span = (Mica::Regex::BoundedBacktracker::MAX_VISITED_BITS // program.state_count - 1).to_i32
      if Mica::Regex::BoundedBacktracker.fits?(program, span)
        Mica::Regex::BoundedBacktracker.allocation_charge(program, span).should be <= program.backtracker_allowance
      end
      haystack = "ab" * 2_000 + "c"
      bytes = allocated_bytes { expression.match(haystack, limits: LIMITS).should_not be_nil }
      bytes.should be <= UNTRUSTED.max_pike_bytes
    end
  end
end
