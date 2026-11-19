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
    # The very first compile plus first search in a fresh process.
    getter process_first_search_seconds : Float64 = 0.0
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

    # Bytes the engine added on top of the loaded haystack.
    def engine_rss_bytes : Int64
      {@peak_rss_bytes - @rss_after_haystack_bytes, 0_i64}.max
    end
  end
end
