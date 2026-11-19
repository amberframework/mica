require "../spec_helper"
require "./accelerated_complexity_spec"

private LIMITS = Mica::Regex::SearchLimits::TRUSTED_INPUT

private def short_match(source : String) : Mica::Regex::ShortMatch?
  Mica::Regex::Expression.new(source, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN).program.plan.short_match
end

# Every match of *program* in *haystack*, one call per search (as the
# benchmark adapters and `match_at_byte_index` loops make them), on
# *engine* with *pool*.
private def spans_by_call(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine,
                          pool : Mica::Regex::CachePool) : Array(Array(Int64))
  list_of_spans = [] of Array(Int64)
  offset = 0
  while offset <= haystack.bytesize
    searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, engine, pool)
    found = searcher.find(offset, Mica::Regex::MatchOptions::None, false).try(&.to_a)
    searcher.finish
    break unless found
    list_of_spans << found
    offset = found[1] > found[0] ? found[1].to_i32 : found[1].to_i32 + 1
  end
  list_of_spans
end

# English-like text: letters a-z by rough frequency, spaces and an
# occasional `x`, so `[a-q][^u-z]{13}x` matches now and then and its
# unanchored DFA meets many overlapping starts.
private def english_like(size : Int32) : String
  random = Random::PCG32.new(20261118_u64)
  letters = "eeeeeeetttttaaaaoooiiinnnsssrrhhlldcumfpgwybvk"
  String.build do |io|
    size.times do
      roll = random.rand(100)
      io << (roll < 16 ? ' ' : (roll < 17 ? 'x' : letters[random.rand(letters.size)]))
    end
  end
end

describe "Mica::Regex short matches" do
  describe "ShortMatch.analyze" do
    it_satisfies "REGEX-R3-short-match", "bounds the match length and finds the final bytes" do
      analysis = short_match("[a-q][^u-z]{13}x").should_not be_nil
      analysis.longest.should eq(1 + 13 * 4 + 1)
      analysis.list_of_final_bytes.should eq(['x'.ord.to_u8])
      both = short_match("ab|cd").should_not be_nil
      both.longest.should eq(2)
      both.list_of_final_bytes.sort.should eq(['b'.ord.to_u8, 'd'.ord.to_u8])
      short_match("(?i)ax").should_not(be_nil).list_of_final_bytes.sort.should eq(['X'.ord.to_u8, 'x'.ord.to_u8])
    end

    it_satisfies "REGEX-R3-short-match", "keeps no final bytes when a match can be empty or end in many bytes" do
      short_match("a?").should_not(be_nil).list_of_final_bytes.should be_empty
      short_match("a[b-z]").should_not(be_nil).list_of_final_bytes.should be_empty
      short_match("\\bé\\b").should_not(be_nil).list_of_final_bytes.should eq([0xA9_u8])
    end

    it_satisfies "REGEX-R3-short-match", "refuses loops and matches longer than its bound" do
      short_match("a+").should be_nil
      short_match("(?:ab)*c").should be_nil
      short_match("a{#{Mica::Regex::ShortMatch::BOUND + 1}}").should be_nil
      short_match("a{#{Mica::Regex::ShortMatch::BOUND}}").should_not be_nil
    end
  end

  describe "searching from each start" do
    it_satisfies "REGEX-R3-short-match", "takes over from a thrashing forward cache and finds what the two-phase search finds" do
      expression = Mica::Regex::Expression.new("[a-q][^u-z]{13}x", compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN)
      program = expression.program
      haystack = english_like(60_000)
      pool = Mica::Regex::CachePool.new(max_bytes: 64_i64 * 1024 * 1024, max_cache_bytes: 96_i64 * 1024)
      expected = spans_by_call(program, haystack, Mica::Regex::Engine::TwoPhase, pool)
      expected.size.should be > 10
      spans_by_call(program, haystack, Mica::Regex::Engine::Auto, pool).should eq(expected)
      spans_by_call(program, haystack, Mica::Regex::Engine::EachStart, pool).should eq(expected)
      lease = program.plan.lease(pool)
      forward = program.plan.forward.should_not be_nil
      lease.forward_cache(forward).should_not(be_nil).thrashing?.should be_true
      program.plan.give_back(lease)
    end

    it_satisfies "REGEX-R3-short-match", "decides Unicode word assertions and finds starts next to non-ASCII text" do
      haystack = "été à l'école, naïve façade; über ÉCOLE été"
      ["\\b\\w{2,5}\\b", "\\B\\w{1,2}\\b", "(?i)\\bé\\w{0,3}", "\\p{L}{3,4}\\b", "(?aW:\\b)\\w{2}"].each do |source|
        program = Mica::Regex::Expression.new(source, compile_limits: Mica::Regex::CompileLimits::TRUSTED_PATTERN).program
        pool = Mica::Regex::CachePool.new
        expected = spans_by_call(program, haystack, Mica::Regex::Engine::PikeVM, pool)
        spans_by_call(program, haystack, Mica::Regex::Engine::EachStart, pool).should eq(expected)
        spans_by_call(program, haystack, Mica::Regex::Engine::Auto, pool).should eq(expected)
      end
    end

    it_satisfies "REGEX-R3-complexity", "from each start stays linear in n with work <= 2·m·(n + 1) when every start reads its longest" do
      # Every start reads 14 bytes and dies on the 15th, no match ever
      # completes, and the final bytes (u-z) are too many to skip by.
      program = SearchComplexity.program("[a-q][^u-z]{13}[u-z]")
      program.plan.short_match.should_not(be_nil).list_of_final_bytes.should be_empty
      measurements = SearchComplexity::SIZES.map do |scale|
        haystack = "a" * (4_000 * scale)
        searcher = Mica::Regex::Searcher.new(program, haystack, SearchComplexity::WIDE, nil, Mica::Regex::Engine::EachStart)
        searcher.find(0, Mica::Regex::MatchOptions::None, false).should be_nil
        searcher.finish
        SearchComplexity::Measurement.new(scale, searcher.meter.operations, program.state_count.to_i64 * (haystack.bytesize + 1))
      end
      SearchComplexity.check("from each start [a-q][^u-z]{13}[u-z]", measurements, 2.0, false).should eq([] of String)
    end
  end
end
