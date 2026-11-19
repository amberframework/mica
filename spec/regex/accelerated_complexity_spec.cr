require "../spec_helper"
require "./search_complexity_spec"

# The complexity families milestone R3 adds (roadmap 6.8): the literal
# accelerators on candidate-dense haystacks, a lazy DFA whose cache
# thrashes, and iteration. Each reads the work the search charged (never
# wall time) at four sizes, as `SearchComplexity` does, and holds it to an
# upper envelope and to linear growth.
module AcceleratedComplexity
  def self.work(program : Mica::Regex::Program, haystack : String, pool : Mica::Regex::CachePool = Mica::Regex::CachePool.default) : {Int64, Mica::Regex::Searcher}
    searcher = Mica::Regex::Searcher.new(program, haystack, SearchComplexity::WIDE, nil, Mica::Regex::Engine::Auto, pool)
    searcher.find(0, Mica::Regex::MatchOptions::None, false)
    {searcher.meter.operations, searcher}
  end

  # Runs a whole scan on one searcher; returns the work and the matches.
  def self.scan_work(program : Mica::Regex::Program, haystack : String,
                     limits : Mica::Regex::SearchLimits = SearchComplexity::WIDE) : {Int64, Int32}
    searcher = Mica::Regex::Searcher.new(program, haystack, limits, nil)
    offset = 0
    count = 0
    while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
      count += 1
      finish = found[1].to_i32
      offset = finish == found[0] ? finish + 1 : finish
    end
    {searcher.meter.operations, count}
  ensure
    searcher.try(&.finish)
  end
end

describe "Mica::Regex accelerated search complexity" do
  describe "accelerators on candidate-dense haystacks" do
    # A literal starts at every third position and a full match never
    # completes, so every candidate is a false positive and the DFA falls
    # back to its start state after each.
    families = [
      {"rare byte", "ab[0-9]{3}x", ->(n : Int32) { "abz" * (n // 3) }, Mica::Regex::Prefilter::Kind::RareByte},
      {"rare pair", "ea[0-9]{3}x", ->(n : Int32) { "eaz" * (n // 3) }, Mica::Regex::Prefilter::Kind::RareByte},
      {"pair literal search", "eaea", ->(n : Int32) { "eae" * (n // 3) }, Mica::Regex::Prefilter::Kind::RareByte},
      {"first bytes", "(?:ab|ba|ca)[0-9]", ->(n : Int32) { "abz" * (n // 3) }, Mica::Regex::Prefilter::Kind::FirstBytes},
      {"packed", "(?:ab|bc|cd|de|ef)[0-9]", ->(n : Int32) { "abzbczcdzdezefz" * (n // 15) }, Mica::Regex::Prefilter::Kind::Packed},
      {"literal search", "aaab|aaac|aaad", ->(n : Int32) { "a" * n }, Mica::Regex::Prefilter::Kind::FirstBytes},
    ]
    families.each do |name, source, haystack_of, kind|
      it_satisfies "REGEX-R3-complexity", "the #{name} prefilter stays linear in n with work <= 16·m·(n + 1) (#{source})" do
        program = SearchComplexity.program(source)
        program.plan.prefilter.try(&.kind).should eq(kind)
        measurements = SearchComplexity::SIZES.map do |scale|
          haystack = haystack_of.call(4_000 * scale)
          operations, _ = AcceleratedComplexity.work(program, haystack)
          SearchComplexity::Measurement.new(scale, operations, program.state_count.to_i64 * (haystack.bytesize + 1))
        end
        SearchComplexity.check("accelerator #{name} #{source}", measurements, 16.0, false).should eq([] of String)
      end
    end

    it_satisfies "REGEX-R3-accelerators", "turns a prefilter off once its candidates come too densely" do
      program = SearchComplexity.program("ab[0-9]{3}x")
      # The x every match needs comes last, so the search runs and the
      # prefilter meets its dense candidates.
      _, searcher = AcceleratedComplexity.work(program, "abz" * 10_000 + "x")
      searcher.prefilter_off?.should be_true
      _, sparse = AcceleratedComplexity.work(program, "ab" + "z" * 10_000 + "ab123x")
      sparse.prefilter_off?.should be_false
    end
  end

  describe "a thrashing lazy-DFA cache" do
    it_satisfies "REGEX-R3-complexity", "(a|b)*a(a|b){20} falls back to the Pike VM and stays linear in n" do
      program = SearchComplexity.program("(a|b)*a(a|b){20}c")
      pool = Mica::Regex::CachePool.new(max_bytes: 64_i64 * 1024 * 1024, max_cache_bytes: 96_i64 * 1024)
      random = Random::PCG32.new(20261118_u64)
      measurements = SearchComplexity::SIZES.map do |scale|
        # The c every match needs comes last, so the DFA reads the whole
        # haystack.
        haystack = String.build do |io|
          (8_000 * scale).times { io << (random.rand(2) == 0 ? 'a' : 'b') }
          io << 'c'
        end
        operations, searcher = AcceleratedComplexity.work(program, haystack, pool)
        searcher.dfa_gave_up?.should be_true
        SearchComplexity::Measurement.new(scale, operations, program.state_count.to_i64 * (haystack.bytesize + 1))
      end
      SearchComplexity.check("cache thrash (a|b)*a(a|b){20}c", measurements, 8.0, false).should eq([] of String)
    end
  end

  describe "iteration" do
    it_satisfies "REGEX-R3-complexity", "\\w+ over words stays linear in n over a whole scan" do
      program = SearchComplexity.program("\\w+")
      measurements = SearchComplexity::SIZES.map do |scale|
        haystack = "word " * (1_000 * scale)
        operations, count = AcceleratedComplexity.scan_work(program, haystack)
        count.should eq(1_000 * scale)
        SearchComplexity::Measurement.new(scale, operations, program.state_count.to_i64 * (haystack.bytesize + 1))
      end
      SearchComplexity.check("iteration \\w+", measurements, 4.0, false).should eq([] of String)
    end

    it_satisfies "REGEX-R3-complexity", "[a-z]+X|[a-z] over a run of letters trips the call's cumulative budget" do
      program = SearchComplexity.program("[a-z]+X|[a-z]")
      haystack = "a" * 20_000
      limits = Mica::Regex::SearchLimits.custom(work_ceiling: 10_000_000_i64)
      error = expect_raises(Mica::Regex::SearchLimitError) { AcceleratedComplexity.scan_work(program, haystack, limits) }
      error.limit_name.should eq("max_work")
      error.limit_value.should eq(10_000_000)
    end
  end
end
