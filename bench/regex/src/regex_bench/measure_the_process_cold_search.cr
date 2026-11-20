require "json"

module RegexBench
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
  # first search.
  class MeasureTheProcessColdSearch
    def initialize(@engine : Engine, @benchmark_case : BenchmarkCase, @rebar_haystack_directory : String)
    end

    def perform : ProcessColdSample
      return ProcessColdSample.new("unsupported", detail: @engine.pending_reason) unless @engine.ready?

      haystack = HaystackBuilder.new(@benchmark_case.haystack, @rebar_haystack_directory).build
      policy = SearchPolicy.new(deadline: @benchmark_case.deadline,
        untrusted_input: @benchmark_case.belongs_to_the_redos_set?)
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
