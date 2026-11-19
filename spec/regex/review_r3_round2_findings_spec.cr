require "../spec_helper"

# Findings of the second R3 review: Unicode and ASCII word assertions mixed
# in one pattern, and the per-cache ceiling on a cache's first reservation.
private UNTRUSTED = Mica::Regex::CompileLimits::UNTRUSTED_PATTERN
private REQUEST   = Mica::Regex::SearchLimits::REQUEST
private ENGINES   = {Mica::Regex::Engine::Auto, Mica::Regex::Engine::NoAccelerators, Mica::Regex::Engine::EachStart, Mica::Regex::Engine::ReversedClasses, Mica::Regex::Engine::TwoPhase,
                     Mica::Regex::Engine::PikeVM, Mica::Regex::Engine::Backtracker}

# Every non-overlapping match of *program* in *haystack* on *engine*, as
# byte spans.
private def scan(program : Mica::Regex::Program, haystack : String, engine : Mica::Regex::Engine) : Array({Int64, Int64})
  list_of_spans = [] of {Int64, Int64}
  searcher = Mica::Regex::Searcher.new(program, haystack, REQUEST, nil, engine)
  offset = 0
  while found = searcher.find(offset, Mica::Regex::MatchOptions::None, false)
    list_of_spans << {found[0], found[1]}
    offset = found[1] > found[0] ? found[1].to_i32 : found[1].to_i32 + 1
    break if offset > haystack.bytesize
  end
  searcher.finish
  list_of_spans
end

describe "Mica::Regex R3 second review findings" do
  it_satisfies "REGEX-R3-dfa", "keeps ASCII and Unicode word assertions apart in one pattern on every engine path" do
    # Each pattern mixes an ASCII-mode word assertion ((?aW)) with a
    # Unicode one; the spans are PCRE2 10.49's.
    {
      {"é\\B(?aW:\\b)é", "éé", [] of {Int64, Int64}},
      {"é\\B(?aW:\\b)é", "aéé", [] of {Int64, Int64}},
      {"\\bé(?aW)\\ba", "éa", [{0_i64, 3_i64}]},
      {"(?aW:\\b)a|é\\ba", "éa", [{2_i64, 3_i64}]},
      {"(?aW:\\b)a|é\\ba", "aéa", [{0_i64, 1_i64}, {3_i64, 4_i64}]},
      {"(?aW:\\b)a|é\\ba", "x éa", [{4_i64, 5_i64}]},
      {"(?:é\\b|(?aW:\\b)é)", "aéa", [{1_i64, 3_i64}]},
      {"(?:é\\b|(?aW:\\b)é)", "aéé", [{1_i64, 3_i64}, {3_i64, 5_i64}]},
      {"é(?aW:\\b)\\b", "éa", [] of {Int64, Int64}},
      {"(?aW:\\B)é\\B", "aéb", [] of {Int64, Int64}},
      {"(?aW:\\B)é\\b", "éé ", [{2_i64, 4_i64}]},
    }.each do |source, haystack, expected|
      program = Mica::Regex::Expression.new(source, compile_limits: UNTRUSTED).program
      ENGINES.each do |engine|
        {source, haystack, engine, scan(program, haystack, engine)}.should eq({source, haystack, engine, expected})
      end
    end
  end

  it_satisfies "REGEX-R3-cache-pool", "holds a cache's first reservation under max_cache_bytes and runs the Pike VM when it cannot fit" do
    # A 1-byte ceiling leaves no room for any cache: the search runs on the
    # Pike VM and still finds the match.
    pool = Mica::Regex::CachePool.new(max_bytes: 65_536_i64, max_cache_bytes: 1_i64)
    expression = Mica::Regex::Expression.new("\\ba", compile_limits: UNTRUSTED, cache_pool: pool)
    expression.match("a", limits: REQUEST).try(&.[0]).should eq("a")
    pool.reserved_bytes.should be < Mica::Regex::CachePool::RESERVATION_BYTES

    # A ceiling below one reservation step but above a cache's fixed parts:
    # each cache reserves no more than the ceiling.
    ceiling = 16_384_i64
    roomy = Mica::Regex::CachePool.new(max_bytes: 1_048_576_i64, max_cache_bytes: ceiling)
    program = Mica::Regex::Expression.new("\\b[a-c]+d", compile_limits: UNTRUSTED).program
    found = Mica::Regex::Searcher.new(program, "xx abcabd", REQUEST, nil, Mica::Regex::Engine::Auto, roomy)
    found.find(0, Mica::Regex::MatchOptions::None, false).try(&.to_a).should eq([3, 9])
    found.last_path.should eq(Mica::Regex::Searcher::Path::LazyDFA)
    roomy.reserved_bytes.should be <= 2 * ceiling
    found.finish
  end
end

# Bytes the collector hands out while the block runs: the least of three
# runs, with collection off during each (see review_r2_round3_findings_spec.cr).
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

describe "Mica::Regex bounded backtracker job stack" do
  it_satisfies "REGEX-R2-limits", "allocates the job stack as a search needs it, within the full bound" do
    expression = Mica::Regex::Expression.new("x[ab]{0,3}c", compile_limits: UNTRUSTED)
    program = expression.program
    haystack = "ab" * 4_000
    span = haystack.bytesize
    Mica::Regex::BoundedBacktracker.fits?(program, span).should be_true
    full_stack = Mica::Regex::AllocationLedger.granules((program.state_count.to_i64 * (span + 1) + 1) * 16)
    bytes = allocated_bytes do
      searcher = Mica::Regex::Searcher.new(program, haystack, REQUEST, nil, Mica::Regex::Engine::Backtracker)
      searcher.find(0, Mica::Regex::MatchOptions::None, true).should be_nil
      searcher.finish
    end
    bytes.should be < full_stack // 4
    Mica::Regex::BoundedBacktracker.allocation_charge(program, span).should be <= program.backtracker_allowance

    # Searches whose stacks run thousands of jobs deep cross every chunk
    # boundary on the way up and on the way down, and agree with the Pike
    # VM: the first alternative climbs to the end and unwinds to the
    # second, which climbs again.
    long = "ab" * 3_000 + "c"
    {"(?:a|b)*y|(?:(a)|b)*c", "(?:(a)|b)*d", "(?:a|b)*c"}.each do |source|
      deep = Mica::Regex::Expression.new(source, compile_limits: UNTRUSTED).program
      Mica::Regex::BoundedBacktracker.fits?(deep, long.bytesize).should be_true
      found = Mica::Regex::Searcher.new(deep, long, REQUEST, nil, Mica::Regex::Engine::Backtracker)
      pike = Mica::Regex::Searcher.new(deep, long, REQUEST, nil, Mica::Regex::Engine::PikeVM)
      {source, found.find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a)}
        .should eq({source, pike.find(0, Mica::Regex::MatchOptions::None, true).try(&.to_a)})
      found.finish
      pike.finish
    end
  end
end
