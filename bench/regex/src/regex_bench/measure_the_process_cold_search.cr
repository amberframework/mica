require "json"

module RegexBench
  module ProcessCold
    # Runs a full collection, outside the clock, just before a process-cold
    # window opens. Building the haystack leaves the runner's own garbage
    # behind, and without this the collection it is owed falls inside the
    # window whenever the engine allocates on the GC heap there: one
    # collection costs about 150 us in any Crystal process on the M1 Max,
    # whatever the engine. PCRE2 allocates with `malloc` and never trips it;
    # Mica, in pure Crystal, did on the 11 Amber 64 KiB cases whose
    # generators leave the collector a few KB short of its trigger
    # (round 6, 2026-11-19). With the collector at rest, a collection inside
    # the window is one the engine's own allocation caused, and it is
    # charged to the engine.
    def self.leave_the_collector_at_rest : Nil
      GC.collect
    end
  end

  # One process-cold sample, written by a runner started with
  # `--process-cold`. `status` is "ok", "limit" or "unsupported".
  record ProcessColdSample, status : String, seconds : Float64 = 0.0, detail : String = "" do
    include JSON::Serializable

    def succeeded? : Bool
      status == "ok"
    end
  end

  # When a runner is started with `--process-cold`, then it builds the
  # case's haystack and times compile plus the first search as the first
  # regex work of the process, and nothing else, so the driver can take as
  # many process-cold samples as it asks for, each in a fresh process.
  # The clock covers exactly what `MeasureACase` times as its process-cold
  # first search, and starts with the collector at rest (see
  # `ProcessCold.leave_the_collector_at_rest`).
  class MeasureTheProcessColdSearch
    def initialize(@engine : Engine, @benchmark_case : BenchmarkCase, @rebar_haystack_directory : String)
    end

    def perform : ProcessColdSample
      return ProcessColdSample.new("unsupported", detail: @engine.pending_reason) unless @engine.ready?

      haystack = HaystackBuilder.new(@benchmark_case.haystack, @rebar_haystack_directory).build
      policy = SearchPolicy.new(deadline: @benchmark_case.deadline,
        untrusted_input: @benchmark_case.belongs_to_the_redos_set?)
      ProcessCold.leave_the_collector_at_rest
      started = Time.instant
      begin
        @engine.compile(@benchmark_case.pattern, @benchmark_case.case_insensitive?, policy).find(haystack, 0, true, false)
      rescue error : LimitReachedError
        return ProcessColdSample.new("limit", (Time.instant - started).total_seconds, error.limit_name)
      end
      ProcessColdSample.new("ok", (Time.instant - started).total_seconds)
    rescue error : UnsupportedCaseError
      ProcessColdSample.new("unsupported", detail: error.message || error.class.name)
    end
  end
end
