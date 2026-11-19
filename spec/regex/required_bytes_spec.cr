require "../spec_helper"

# A search that checks first for the ASCII bytes every match contains (see
# "Required bytes" in docs/regex.md), and a first search that hands a
# pattern the backtracker struggles with to the plan.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def compiled_program(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
end

describe "Mica::Regex required bytes" do
  describe "Program#list_of_required_bytes" do
    it_satisfies "REGEX-R3-required-bytes", "holds the rarest ASCII bytes every match reads" do
      compiled_program("(a|aa)*c").list_of_required_bytes.should eq(['c'.ord.to_u8])
      compiled_program("\\w+\\s+Holmes").list_of_required_bytes.should eq(['H', 'm', 'l'].map(&.ord.to_u8))
      compiled_program("a(?:b|c:)d").list_of_required_bytes.should eq(['d', 'a'].map(&.ord.to_u8))
      compiled_program("x|y").list_of_required_bytes.should be_empty
      compiled_program("c?").list_of_required_bytes.should be_empty
    end
  end

  describe "Searcher#find" do
    it_satisfies "REGEX-R3-required-bytes", "runs no engine when a byte every match needs is missing" do
      haystack = "a" * 10_000
      searcher = Mica::Regex::Searcher.new(compiled_program("(a|aa)*c"), haystack, LIMITS, nil)
      searcher.find(0, Mica::Regex::MatchOptions::None, true).should be_nil
      searcher.last_path.should eq(Mica::Regex::Searcher::Path::None)
      # Validation and one scan for the c.
      searcher.meter.operations.should be <= 2 * haystack.bytesize
      searcher.finish
    end

    it_satisfies "REGEX-R3-required-bytes", "reads the haystack once per required byte over an iteration call" do
      program = compiled_program("\\w+:")
      haystack = "ab: " * 2_000
      with_check = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil)
      without_check = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, Mica::Regex::Engine::NoAccelerators)
      counts = {with_check, without_check}.map do |searcher|
        offset = 0
        count = 0
        while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
          count += 1
          offset = found[1].to_i32
        end
        searcher.finish
        count
      end
      counts.should eq({2_000, 2_000})
      # One read of the haystack, plus a few operations the two paths count
      # differently at its end.
      (with_check.meter.operations - without_check.meter.operations).should be <= haystack.bytesize + 64
    end

    it_satisfies "REGEX-R3-required-bytes", "agrees with the engines that do not check on every engine path" do
      list_of_cases = {
        {"(a|aa)*c", "aaaa"}, {"(a|aa)*c", "aaac"}, {"(?i)x\\d", "X1"}, {"a(?:b|c:)d", "ac:d abd"},
        {"\\bH\\w+", "say Hi"}, {"(?m)^:x$", "a\n:x\n"},
      }
      list_of_cases.each do |source, haystack|
        expected = Mica::Regex::Searcher.new(compiled_program(source), haystack, LIMITS, nil, Mica::Regex::Engine::PikeVM)
          .find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a)
        found = Mica::Regex::Searcher.new(compiled_program(source), haystack, LIMITS, nil)
          .find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a)
        found.should eq(expected)
      end
    end
  end

  describe "a first search" do
    it_satisfies "REGEX-R3-first-search", "checks the required bytes of a small program before the backtracker runs" do
      pattern = Mica::Regex::Expression.new("(a|a)*b", compile_limits: TRUSTED)
      pattern.match("a" * 200, limits: LIMITS).should be_nil
      pattern.program.plan_built?.should be_false
    end

    it_satisfies "REGEX-R3-first-search", "hands a search the backtracker has not decided within its visits to the plan" do
      haystack = "a" * 255 + "!"
      first = Mica::Regex::Expression.new("(a|a)*$", compile_limits: TRUSTED)
      searcher = Mica::Regex::Searcher.first_search(first.program, haystack, LIMITS, nil, Mica::Regex::CachePool.default)
      searcher.find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a).should eq([256, 256, -1, -1])
      searcher.last_path.should_not eq(Mica::Regex::Searcher::Path::Backtracker)
      first.program.plan_built?.should be_true
      # Within the backtracker's visits and the plan's work, not the
      # backtracker's worst case (m·(n + 1) visits).
      worst = first.program.state_count.to_i64 * (haystack.bytesize + 1)
      searcher.meter.operations.should be < worst
      searcher.finish
    end
  end
end
