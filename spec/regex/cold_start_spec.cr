require "../spec_helper"

# The cold-start path: a program compiled and searched once. Its first
# search follows a class run's copies from the run's block without a run
# lookup per state, marking only each copy's entry, and reuses the pool's
# spare backtracker rather than allocating a bitset and job stack (see
# "First searches" in docs/regex.md).
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private LIMITS  = Mica::Regex::SearchLimits::TRUSTED_INPUT
private NONE    = Mica::Regex::MatchOptions::None

private def program_of(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
end

# The match span a first search of a new program finds, with the
# operations it charged.
private def first_search_span(source : String, haystack : String,
                              pool : Mica::Regex::CachePool = Mica::Regex::CachePool.new) : {Slice(Int64)?, Int64}
  program = program_of(source)
  program.runs_pending?.should be_true unless program.list_of_runs.empty?
  searcher = Mica::Regex::Searcher.first_search(program, haystack, LIMITS, nil, pool)
  found = searcher.find(0, NONE, false).try(&.dup)
  operations = searcher.meter.operations
  searcher.finish
  {found, operations}
end

# The span the plan's engines find for the same search.
private def plan_span(source : String, haystack : String) : Slice(Int64)?
  program = program_of(source)
  program.end_first_searches
  searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil)
  found = searcher.find(0, NONE, false).try(&.dup)
  searcher.finish
  found
end

describe "Mica::Regex cold start" do
  it_satisfies "REGEX-R3-first-search", "follows class runs whole and finds what the plan finds" do
    cases = {
      {"[0-9A-Za-z_]{20}", "b" * 25},
      {"[0-9A-Za-z_]{20}", "b" * 19 + "!" + "c" * 20},
      {"\\p{L}{40}", "δ" * 39 + "1" + "Ж" * 40},
      {"\\p{L}{40}", "δ" * 39},
      {"x\\p{L}{3,40}y", "x" + "日本語" * 5 + "y"},
      {"(?:\\w{2}x){30}q", "abx" * 31 + "q"},
      {"(?:\\w{2}x){30}q", "abx" * 29 + "q"},
      {"\\b\\w{12,}\\b", "short words then extraordinarily long ones"},
      {"[a-q][^u-z]{40}x", "a" + "b" * 40 + "x"},
      {"\\p{Greek}{8}", "abc αβγδεζηθ def"},
      {"(?:\\p{Lowercase}|\\p{Uppercase}){12}", "ab ABCDEFabcdefGH!"},
    }
    cases.each do |(source, haystack)|
      found, _ = first_search_span(source, haystack)
      found.should eq(plan_span(source, haystack))
    end
  end

  it_satisfies "REGEX-R3-first-search", "charges a run one operation per state it steps through" do
    # Forty more copies over forty more bytes cost forty more bytes
    # validated and forty more steps: no run lookups per state.
    short_program = program_of("[0-9A-Za-z_]{40}")
    short_program.list_of_runs.size.should eq(1)
    short_found, short_operations = first_search_span("[0-9A-Za-z_]{40}", "b" * 40)
    long_found, long_operations = first_search_span("[0-9A-Za-z_]{80}", "b" * 80)
    short_found.should eq(Slice[0_i64, 40_i64])
    long_found.should eq(Slice[0_i64, 80_i64])
    (long_operations - short_operations).should eq(40 + 40)
  end

  it_satisfies "REGEX-R3-first-search", "keeps one spare backtracker per pool, holding no program, for the next first search" do
    pool = Mica::Regex::CachePool.new
    first_search_span("[a-z]{30}", "q" * 40, pool)
    spare = pool.take_spare_backtracker(program_of("\\d+")).should_not be_nil
    pool.take_spare_backtracker(program_of("\\d+")).should be_nil
    pool.keep_spare_backtracker(spare)
    # The next first search takes the spare and gives it back.
    found, _ = first_search_span("\\p{L}{10}", "ж" * 10, pool)
    found.should eq(Slice[0_i64, 20_i64])
    pool.take_spare_backtracker(program_of("\\d+")).should be(spare)
    Mica::Regex::BoundedBacktracker.spare_retained_bytes.should be <= 64 * 1024
  end

  it_satisfies "REGEX-R3-first-search", "lists each run's block once with its copy count" do
    program = program_of("a\\p{L}{50}b")
    states = 0_i64
    program.each_distinct_state { |_, copies| states += copies }
    states.should eq(program.state_count)
  end
  it_satisfies "REGEX-R3-first-search", "hands a thrashing unanchored DFA over to the search from each start at its first clear" do
    random = Random.new(20261119)
    letters = "abcdefghijklmnopqrst  "
    haystack = String.build { |io| 200_000.times { io << letters[random.rand(letters.size)] } } + "a" + "b" * 80 + "x"
    pool = Mica::Regex::CachePool.new(max_cache_bytes: 256_i64 * 1024)
    program = Mica::Regex::Expression.new("[a-q][^u-z]{80}x", compile_limits: TRUSTED, cache_pool: pool).program
    program.end_first_searches
    searcher = Mica::Regex::Searcher.new(program, haystack, LIMITS, nil, Mica::Regex::Engine::Auto, pool)
    found = searcher.find(0, NONE, false).try(&.dup)
    searcher.finish
    found.should eq(plan_span("[a-q][^u-z]{80}x", haystack))
    found.should_not be_nil
    plan = program.plan
    dfa = plan.forward.should_not be_nil
    cache = plan.lease(pool).forward_cache(dfa).should_not be_nil
    cache.thrashing?.should be_true
    cache.clears.should eq(1)
  end
end
