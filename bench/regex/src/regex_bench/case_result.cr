require "json"

module RegexBench
  # What one engine process reports for one case. Written by the runner
  # programs as one JSON line and read back by the report writer.
  #
  # `status` is one of:
  # - "ok": every measurement ran;
  # - "limit": the engine stopped on a limit (`limit_name` says which);
  # - "unsupported": the engine cannot run the case (`detail` says why);
  # - "pending": the engine is not built on this branch;
  # - "timeout": the driver stopped the process at its time cap;
  # - "skipped": a smaller size of the same ReDoS family timed out;
  # - "crashed": the process exited without a result.
  struct CaseResult
    include JSON::Serializable

    getter case_id : String
    getter corpus : String
    getter group : String
    getter subgroup : String
    getter model : String
    getter engine : String
    getter status : String
    getter detail : String = ""
    getter limit_name : String = ""
    getter family : String = ""
    getter size_units : Int64 = 0
    getter deadline_ms : Int64 = 0
    getter haystack_bytes : Int64 = 0
    getter haystack_checksum : String = ""
    getter count : Int64 = -1
    getter expected_count : Int64 = BenchmarkCase::NO_EXPECTED_COUNT
    # Compile alone.
    getter compile : Statistics = Statistics.new
    # Compile plus the first search, a new compiled pattern each sample.
    getter cold_first_search : Statistics = Statistics.new
    # The very first compile plus first search in the process that took the
    # other measurements.
    getter process_first_search_seconds : Float64 = 0.0
    # Compile plus the first search as the first regex work of a fresh
    # runner process, one sample per process, each process started right
    # after an untimed page-in of the runner (see `PageInTheRunnerImage`).
    # Empty in runs recorded before these samples existed.
    getter process_cold : Statistics = Statistics.new
    # The process-cold samples themselves, in the order they were taken.
    getter list_of_process_cold_seconds : Array(Float64) = [] of Float64
    # One full iteration of the model with an already compiled pattern.
    getter warm_search : Statistics = Statistics.new
    # Seconds until the engine stopped, for "limit" results.
    getter seconds_until_limit : Float64 = 0.0
    getter rss_after_haystack_bytes : Int64 = 0
    getter peak_rss_bytes : Int64 = 0

    def initialize(*, benchmark_case : BenchmarkCase, @engine : String, @status : String, @detail = "",
                   @limit_name = "", @haystack_bytes = 0_i64, @haystack_checksum = "", @count = -1_i64,
                   @compile = Statistics.new, @cold_first_search = Statistics.new,
                   @process_first_search_seconds = 0.0, @warm_search = Statistics.new,
                   @seconds_until_limit = 0.0, @rss_after_haystack_bytes = 0_i64, @peak_rss_bytes = 0_i64)
      @case_id = benchmark_case.id
      @corpus = benchmark_case.corpus
      @group = benchmark_case.group
      @subgroup = benchmark_case.subgroup
      @model = benchmark_case.model
      @family = benchmark_case.family
      @size_units = benchmark_case.size_units
      @deadline_ms = benchmark_case.deadline_ms
      @expected_count = benchmark_case.expected_count
    end

    def succeeded? : Bool
      @status == "ok"
    end

    def stopped_on_a_limit? : Bool
      @status == "limit"
    end

    # The median of the case's primary metric (see
    # `BenchmarkCase#primary_metric`), in seconds.
    def primary_median : Float64
      @model == "compile" ? @compile.median : @warm_search.median
    end

    # Wall time of one search for the ReDoS tables: the warm median when the
    # search finished, the time until the limit otherwise.
    def search_seconds : Float64
      stopped_on_a_limit? ? @seconds_until_limit : @warm_search.median
    end

    # The process-cold median in seconds: the median of the fresh-process
    # samples, or the single in-process sample of an older run.
    def process_cold_seconds : Float64
      @process_cold.has_samples? ? @process_cold.median : @process_first_search_seconds
    end

    # Returns a copy carrying *list_of_seconds* as its process-cold samples.
    def with_process_cold(list_of_seconds : Array(Float64)) : self
      copy = dup
      copy.process_cold = Statistics.of(list_of_seconds)
      copy.list_of_process_cold_seconds = list_of_seconds
      copy
    end

    protected setter process_cold : Statistics
    protected setter list_of_process_cold_seconds : Array(Float64)

    # Bytes the engine added on top of the loaded haystack.
    def engine_rss_bytes : Int64
      {@peak_rss_bytes - @rss_after_haystack_bytes, 0_i64}.max
    end
  end
end
