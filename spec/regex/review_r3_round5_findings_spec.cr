require "../spec_helper"

# Findings of the fifth R3 review: before the plan builds a program's
# states, a state read finds its `ClassRun` by a binary search, and the
# engines that read states then (a first search's backtracker, and the
# Pike VM and backtracker a `Searcher` forces) charge each run the read
# looks at to the call's meter before it looks, as does a first search's
# required-byte analysis. max_work and the deadline bound the whole call.
private TRUSTED = Mica::Regex::CompileLimits::TRUSTED_PATTERN
private NONE    = Mica::Regex::MatchOptions::None

# The operations a search had charged when it raised *error*.
private def operations_of(error : Mica::Regex::SearchLimitError) : Int64
  error.message.to_s[/A search of (\d+) operations/, 1].to_i64
end

# Limits whose allowance is exactly *ceiling* operations.
private def ceiling_limits(ceiling : Int64) : Mica::Regex::SearchLimits
  Mica::Regex::SearchLimits.custom(work_ceiling: ceiling, work_per_byte: 1_000_000_i64)
end

private def program_of(source : String) : Mica::Regex::Program
  Mica::Regex::Expression.new(source, compile_limits: TRUSTED).program
end

# A searcher of *program* over *haystack*: a first search (`FirstSearch`)
# for `Engine::Backtracker`, a forced engine otherwise.
private def searcher_for(program : Mica::Regex::Program, haystack : String, limits : Mica::Regex::SearchLimits,
                         engine : Mica::Regex::Engine) : Mica::Regex::Searcher
  pool = Mica::Regex::CachePool.new
  if engine.backtracker?
    Mica::Regex::Searcher.first_search(program, haystack, limits, nil, pool)
  else
    Mica::Regex::Searcher.new(program, haystack, limits, nil, engine, pool)
  end
end

# The operations one search of a new program compiled from *source* over
# *haystack* charges when nothing stops it.
private def full_cost(source : String, haystack : String, engine : Mica::Regex::Engine) : Int64
  searcher = searcher_for(program_of(source), haystack, ceiling_limits(Int64::MAX // 2), engine)
  searcher.find(0, NONE, true)
  operations = searcher.meter.operations
  searcher.finish
  operations
end

# Checks that a search of a new program compiled from *source* over
# *haystack* on *engine* stops exactly one operation past each allowance
# spread over its cost after validation, with its runs still pending.
private def expect_stops_at_the_allowance(source : String, haystack : String, engine : Mica::Regex::Engine) : Nil
  total = full_cost(source, haystack, engine)
  first = haystack.bytesize.to_i64 + 1
  8.times do |step|
    ceiling = first + (total - first - 1) * step // 8
    program = program_of(source)
    error = expect_raises(Mica::Regex::SearchLimitError) do
      searcher_for(program, haystack, ceiling_limits(ceiling), engine).find(0, NONE, true)
    end
    error.limit_name.should eq("max_work")
    {source, engine, ceiling, operations_of(error)}.should eq({source, engine, ceiling, ceiling + 1})
    program.runs_pending?.should be_true
  end
end

describe "Mica::Regex R3 fifth review findings" do
  it_satisfies "REGEX-R3-first-search", "charges the runs a first search's state reads look at, stopping one operation past the allowance" do
    # 1,000 runs and 703,004 states: before the fix each state read walked
    # every run uncharged, and the whole first search charged about
    # 11,000 operations while it took milliseconds.
    source = "(?:\\w{2}x){1000}q"
    haystack = "abx" * 80
    program = program_of(source)
    program.list_of_runs.size.should eq(1_000)
    program.run_reads_per_state.should eq(1_000.bit_length + 1)
    ceiling = 20_000_i64
    error = expect_raises(Mica::Regex::SearchLimitError) do
      searcher_for(program, haystack, ceiling_limits(ceiling), Mica::Regex::Engine::Backtracker).find(0, NONE, true)
    end
    error.limit_name.should eq("max_work")
    operations_of(error).should eq(ceiling + 1)
    program.runs_pending?.should be_true
    program.plan_built?.should be_false
  end

  it_satisfies "REGEX-R3-first-search", "stops every engine that reads pending runs one operation past the allowance" do
    {Mica::Regex::Engine::Backtracker, Mica::Regex::Engine::PikeVM}.each do |engine|
      expect_stops_at_the_allowance("(?:\\w{2}x){200}q", "abx" * 80, engine)
      expect_stops_at_the_allowance("\\p{L}{3}\\p{N}{40}", "δ" * 100, engine)
      expect_stops_at_the_allowance("(?:1\\pL{4}){30}!", "1abcd" * 40, engine)
    end
  end

  it_satisfies "REGEX-R3-first-search", "charges a state read no more than the binary search over the runs" do
    {"\\w{2}", "(?:\\w{2}x){7}q", "(?:\\w{2}x){8}q", "(?:\\w{2}x){100}q"}.each do |source|
      program = program_of(source)
      runs = program.list_of_runs.size
      runs.should be > 0
      program.run_reads_per_state.should eq(runs.bit_length + 1)
      meter = Mica::Regex::SearchMeter.new(ceiling_limits(Int64::MAX // 2), program.state_count, 0, nil)
      most = 0_i64
      program.state_count.times do |index|
        before = meter.operations
        program.state_at(index, meter, 0).should eq(program.state_at(index))
        most = Math.max(most, meter.operations - before)
      end
      most.should be <= program.run_reads_per_state
      program.runs_pending?.should be_true
      # Once built, a read charges nothing.
      states = program.list_of_states
      before = meter.operations
      program.state_count.times { |index| program.state_at(index, meter, 0).should eq(states[index]) }
      meter.operations.should eq(before)
    end
  end

  it_satisfies "REGEX-R3-required-bytes", "charges a first search's required-byte analysis before it reads, stopping one operation past the allowance" do
    source = "x[a-z]{64}y"
    haystack = "x" + "a" * 100
    analyzed = program_of(source)
    analyzed.required_bytes_for_first_search(haystack.bytesize).should_not be_nil
    searcher = searcher_for(analyzed, haystack, ceiling_limits(Int64::MAX // 2), Mica::Regex::Engine::Backtracker)
    searcher.find(0, NONE, true).should be_nil
    without_analysis = searcher.meter.operations
    with_analysis = full_cost(source, haystack, Mica::Regex::Engine::Backtracker)
    analysis = with_analysis - without_analysis
    analysis.should be > 0
    analysis.should be <= program_of(source).required_bytes_analysis_bound(haystack.bytesize)
    validation = haystack.bytesize.to_i64
    4.times do |step|
      ceiling = validation + 1 + (analysis - 1) * step // 4
      program = program_of(source)
      error = expect_raises(Mica::Regex::SearchLimitError) do
        searcher_for(program, haystack, ceiling_limits(ceiling), Mica::Regex::Engine::Backtracker).find(0, NONE, true)
      end
      operations_of(error).should eq(ceiling + 1)
    end
  end
end
