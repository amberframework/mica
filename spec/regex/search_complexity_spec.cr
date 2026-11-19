require "../spec_helper"

# The search complexity families of milestone R2 (roadmap 6.8): each
# varies one quantity (n, haystack bytes; m, program states; c, capture
# slots) at four sizes (x1, x2, x4, x8) while the others stay fixed, and
# reads the work the search charged to its meter (never wall time).
#
# - **Upper envelope:** at every size, work <= C x the stated bound, with C
#   committed per family below.
# - **Linear growth:** work at x8 <= 8 x 1.25 x work at x1.
# - **Lower bound** (families built to force the worst path): work at x8
#   >= 8 / 1.25 x work at x1 minus the fixed part, so the counter really
#   counts what the bound charges.
#
# Set MICA_COMPLEXITY_REPORT=path to write every measurement as TSV.
module SearchComplexity
  SIZES = [1, 2, 4, 8]
  # Limits wide enough that no family trips them.
  WIDE    = Mica::Regex::SearchLimits.custom(work_ceiling: Int64::MAX, work_per_byte: 1_000_000_i64)
  TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN

  record Measurement, size : Int32, operations : Int64, bound : Int64

  def self.program(source : String) : Mica::Regex::Program
    Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
  end

  # Runs one search and returns the work it charged (validation included).
  def self.work(program : Mica::Regex::Program, haystack : String, engine = Mica::Regex::Engine::Auto,
                captures = true) : Int64
    searcher = Mica::Regex::Searcher.new(program, haystack, WIDE, nil, engine)
    searcher.find(0, Mica::Regex::MatchOptions::None, captures)
    searcher.meter.operations
  ensure
    searcher.try(&.finish)
  end

  # Runs every search of a scan (each_match's offsets) on one searcher and
  # returns the work it charged.
  def self.scan_work(program : Mica::Regex::Program, haystack : String) : Int64
    searcher = Mica::Regex::Searcher.new(program, haystack, WIDE, nil)
    offset = 0
    while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
      finish = found[1].to_i32
      offset = finish == found[0] ? finish + 1 : finish
    end
    searcher.meter.operations
  ensure
    searcher.try(&.finish)
  end

  # Checks the envelope and the growth of *measurements*, records them,
  # and returns a description of any failure.
  def self.check(name : String, measurements : Array(Measurement), envelope : Float64, lower_bound : Bool) : Array(String)
    problems = [] of String
    measurements.each do |measurement|
      limit = envelope * measurement.bound
      if measurement.operations > limit
        problems << "#{name} at x#{measurement.size}: #{measurement.operations} ops > #{envelope} x bound #{measurement.bound}"
      end
    end
    first = measurements.first
    last = measurements.last
    factor = last.size // first.size
    result = Mica::Testing::Complexity::Result.new(name, first.size, factor, first.operations, last.operations, 1.25)
    COMPLEXITY_RESULTS << result
    problems << "#{name}: growth #{result.ratio.round(2)} over x#{factor} is not linear" unless result.linear?
    if lower_bound && result.ratio < factor / 1.25
      problems << "#{name}: growth #{result.ratio.round(2)} over x#{factor} is below linear, so the counter misses work"
    end
    problems
  end
end

describe "Mica::Regex search complexity" do
  describe "n (haystack bytes)" do
    families = [
      {"(a+)+$", ->(n : Int32) { "a" * n + "b" }},
      {"(a|a)*b", ->(n : Int32) { "a" * n }},
      {"(a|aa)*c", ->(n : Int32) { "a" * n }},
      {"(x+x+)+y", ->(n : Int32) { "x" * n }},
      {"(.*a){20}", ->(n : Int32) { "a" * n }},
      {"^(\\w+\\s?)*$", ->(n : Int32) { "ab " * (n // 3) + "!" }},
      {"^([a-zA-Z0-9])(([\\-.]|[_]+)?([a-zA-Z0-9]+))*(@){1}[a-z0-9]+[.]{1}(([a-z]{2,3})|([a-z]{2,3}[.]{1}[a-z]{2,3}))$",
       ->(n : Int32) { "a" * n + "!" }},
      {".*(?:.*=.*)", ->(n : Int32) { "x=" + "x" * n }},
      {"^[\\s\\x{200C}]+|[\\s\\x{200C}]+$", ->(n : Int32) { " " * n + "x" }},
    ]
    families.each do |source, haystack_of|
      it_satisfies "REGEX-R2-complexity", "#{source} stays linear in n with work <= 4·m·(c + 1)·(n + 1)" do
        program = SearchComplexity.program(source)
        state_count = program.state_count.to_i64
        slot_count = program.slot_count.to_i64
        # The two-phase path may switch from the backtracker to the Pike VM
        # for captures as the span grows, so it is held to the envelope; the
        # forced Pike VM path (the worst case) is held to linear growth too.
        two_phase = [] of SearchComplexity::Measurement
        pike = [] of SearchComplexity::Measurement
        SearchComplexity::SIZES.each do |scale|
          haystack = haystack_of.call(500 * scale)
          bound = state_count * (slot_count + 1) * (haystack.bytesize + 1)
          two_phase << SearchComplexity::Measurement.new(scale, SearchComplexity.work(program, haystack), bound)
          operations = SearchComplexity.work(program, haystack, Mica::Regex::Engine::PikeVM)
          pike << SearchComplexity::Measurement.new(scale, operations, bound)
        end
        problems = SearchComplexity.check(source, pike, 4.0, true)
        problems.concat(SearchComplexity.check("#{source} (two-phase)", two_phase, 4.0, false).reject(&.includes?("growth")))
        problems.should eq([] of String)
      end
    end
  end

  describe "m (program states)" do
    haystack = String.build { |io| 65_536.times { |index| io << ('a' + index % 26) } }
    literal_haystack = String.build { |io| 65_536.times { |index| io << "abcdefghijklmnopqrstuvwxyz0123456789"[index % 36] } }
    families = [
      # Digits too, so the haystack holds the bytes every literal needs and
      # the search runs past the required-byte check.
      {"alternation of k 8-byte literals", ->(k : Int32) { (0...k).join('|') { |index| "lit%05dx" % index } }, literal_haystack},
      {"a{k}", ->(k : Int32) { "a{#{k}}" }, "a" * 65_536},
      {"[\\p{L}\\p{N}]{1,k}", ->(k : Int32) { "[\\p{L}\\p{N}]{1,#{k}}" }, haystack},
    ]
    families.each do |name, source_of, text|
      it_satisfies "REGEX-R2-complexity", "#{name} over 64 KiB stays linear in m with work <= 4·m·(c + 1)·(n + 1)" do
        haystack_bytes = text.bytesize.to_i64
        measurements = SearchComplexity::SIZES.map do |scale|
          program = SearchComplexity.program(source_of.call(8 * scale))
          state_count = program.state_count.to_i64
          bound = state_count * (program.slot_count + 1) * (haystack_bytes + 1)
          SearchComplexity::Measurement.new(scale, SearchComplexity.work(program, text), bound)
        end
        SearchComplexity.check(name, measurements, 4.0, false).should eq([] of String)
      end
    end
  end

  describe "c (capture slots)" do
    it_satisfies "REGEX-R2-complexity", "slot copies grow linearly in c with m and L fixed, on the forced Pike VM path" do
      max_groups = 64
      haystack = "x" * 64
      sources = SearchComplexity::SIZES.map do |scale|
        groups = 8 * scale
        # Each () emits two slot saves; each (?:|) one split, so two of
        # them pad a missing group and every program has the same states.
        "x{64}" + "()" * groups + "(?:|)(?:|)" * (max_groups - groups)
      end
      programs = sources.map { |source| SearchComplexity.program(source) }
      programs.map(&.state_count).uniq.size.should eq(1)
      measurements = SearchComplexity::SIZES.zip(programs).map do |scale, program|
        state_count = program.state_count.to_i64
        slot_count = program.slot_count.to_i64
        bound = state_count * slot_count * (haystack.bytesize + 1)
        operations = SearchComplexity.work(program, haystack, Mica::Regex::Engine::PikeVM)
        SearchComplexity::Measurement.new(scale, operations, bound)
      end
      SearchComplexity.check("c family", measurements, 2.0, false).should eq([] of String)
      # The copies are really charged: c x8 must cost clearly more.
      (measurements.last.operations > 3 * measurements.first.operations).should be_true
    end

    it_satisfies "REGEX-R2-complexity", "the backtracker stays within m·(L + 1) visits plus undo entries" do
      program = SearchComplexity.program("(a|b)*(c)")
      [16, 32, 64, 128].each do |length|
        haystack = "ab" * (length // 2) + "c"
        operations = SearchComplexity.work(program, haystack, Mica::Regex::Engine::Backtracker)
        bound = 2_i64 * program.state_count * (haystack.bytesize + 1) + program.slot_count + haystack.bytesize
        (operations <= bound).should be_true
      end
    end
  end

  describe "iteration" do
    it_satisfies "REGEX-R2-complexity", "a FirstLine scan stays linear in n: the line feed search is made once and charged" do
      program = SearchComplexity.program("a")
      first_line = Mica::Regex::Expression.new("a", Mica::Regex::CompileOptions::FirstLine,
        compile_limits: SearchComplexity::TRUSTED).program
      measurements = SearchComplexity::SIZES.map do |scale|
        haystack = "a" * (2_000 * scale)
        operations = SearchComplexity.scan_work(first_line, haystack)
        SearchComplexity::Measurement.new(scale, operations, 4_i64 * (haystack.bytesize + 1) * program.state_count)
      end
      SearchComplexity.check("FirstLine scan of a over a*n", measurements, 4.0, true).should eq([] of String)
    end

    it_satisfies "REGEX-R2-limits", "charges the FirstLine line feed search, so max_work stops it" do
      compiled = Mica::Regex::Expression.new("x", Mica::Regex::CompileOptions::FirstLine,
        compile_limits: SearchComplexity::TRUSTED)
      haystack = "a" * 100_000
      # Validation alone fits the allowance; the line feed search does not.
      tight = Mica::Regex::SearchLimits.custom(work_ceiling: 150_000_i64)
      expect_raises(Mica::Regex::SearchLimitError, "max_work") { compiled.match(haystack, limits: tight) }
    end
  end
end
