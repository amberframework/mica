require "json"

module RegexBench
  # Seconds for the four metrics the bar is judged on: the primary (warm
  # search, or compile for the `compile` model), compile, cold first search
  # (compile plus one search in a warm process) and process-cold (compile
  # plus first search as the first regex work of a fresh process). On a
  # case they are medians; on a group, geometric means of the eligible
  # cases' medians.
  struct MetricSeconds
    include JSON::Serializable

    getter warm : Float64 = 0.0
    getter compile : Float64 = 0.0
    getter cold : Float64 = 0.0
    getter process_cold : Float64 = 0.0

    def initialize(@warm = 0.0, @compile = 0.0, @cold = 0.0, @process_cold = 0.0)
    end

    # Geometric means over *list_of_seconds*, each metric over its values
    # above zero.
    def self.geometric_means(list_of_seconds : Array(MetricSeconds)) : self
      new(warm: mean_of(list_of_seconds, &.warm), compile: mean_of(list_of_seconds, &.compile),
        cold: mean_of(list_of_seconds, &.cold), process_cold: mean_of(list_of_seconds, &.process_cold))
    end

    private def self.mean_of(list_of_seconds : Array(MetricSeconds), & : MetricSeconds -> Float64) : Float64
      Statistics.geometric_mean(list_of_seconds.map { |seconds| yield seconds }.select(&.> 0))
    end
  end

  # One engine's result on one case, set against the baseline's.
  # A ratio is engine median / baseline median: below 1 the engine is
  # faster. A ratio is 0 when it cannot be computed (see `eligible`).
  struct CaseComparison
    include JSON::Serializable

    getter case_id : String
    getter group : String
    getter subgroup : String
    getter model : String
    getter engine : String
    getter status : String
    getter baseline_status : String
    # Both ran to completion and their counts agree.
    getter? eligible : Bool
    getter detail : String
    getter primary_ratio : Float64
    getter compile_ratio : Float64
    getter cold_ratio : Float64
    getter process_cold_ratio : Float64 = 0.0
    getter baseline_primary_median_seconds : Float64
    getter engine_primary_median_seconds : Float64
    getter baseline_relative_spread : Float64
    getter engine_relative_spread : Float64
    getter count : Int64
    getter baseline_count : Int64
    # The batch each engine timed its primary metric's samples in (see
    # `Statistics#iterations_per_sample`).
    getter engine_iterations_per_sample : Int32 = 1
    getter baseline_iterations_per_sample : Int32 = 1
    # The medians behind the ratios.
    getter engine_seconds : MetricSeconds = MetricSeconds.new
    getter baseline_seconds : MetricSeconds = MetricSeconds.new

    def initialize(*, @case_id, @group, @subgroup, @model, @engine, @status, @baseline_status, @eligible, @detail,
                   @primary_ratio, @compile_ratio, @cold_ratio, @baseline_primary_median_seconds,
                   @engine_primary_median_seconds, @baseline_relative_spread, @engine_relative_spread,
                   @count, @baseline_count, @engine_iterations_per_sample = 1, @baseline_iterations_per_sample = 1,
                   @process_cold_ratio = 0.0, @engine_seconds = MetricSeconds.new, @baseline_seconds = MetricSeconds.new)
    end

    def slower_than_the_baseline? : Bool
      @eligible && @primary_ratio > 1.0
    end
  end

  # Geometric means of the ratios of one engine over one group's eligible
  # cases.
  struct GroupSummary
    include JSON::Serializable

    getter engine : String
    getter group : String
    getter case_count : Int32
    getter eligible_count : Int32
    getter primary_geometric_mean : Float64
    getter compile_geometric_mean : Float64
    getter cold_geometric_mean : Float64
    getter process_cold_geometric_mean : Float64 = 0.0
    getter slower_count : Int32
    # Geometric means of the eligible cases' medians, so every ratio has
    # its absolute times beside it.
    getter engine_seconds : MetricSeconds = MetricSeconds.new
    getter baseline_seconds : MetricSeconds = MetricSeconds.new

    def initialize(*, @engine, @group, @case_count, @eligible_count, @primary_geometric_mean,
                   @compile_geometric_mean, @cold_geometric_mean, @slower_count, @process_cold_geometric_mean = 0.0,
                   @engine_seconds = MetricSeconds.new, @baseline_seconds = MetricSeconds.new)
    end
  end

  # One engine on one ReDoS case.
  struct RedosCell
    include JSON::Serializable

    getter engine : String
    getter status : String
    getter seconds : Float64
    getter limit_name : String
    getter? matched : Bool

    def initialize(*, @engine, @status, @seconds, @limit_name, @matched)
    end

    # PCRE2 stopped on its match limit or similar, or ran past one second
    # or the driver's cap.
    def counts_as_a_redos_loss? : Bool
      @status == "limit" || @status == "timeout" || (@status == "ok" && @seconds > 1.0)
    end
  end

  struct RedosRow
    include JSON::Serializable

    getter family : String
    getter pattern : String
    getter size_units : Int64
    getter haystack_bytes : Int64
    getter cells : Array(RedosCell)

    def initialize(*, @family, @pattern, @size_units, @haystack_bytes, @cells)
    end
  end

  # Whether one engine kept every search of one ReDoS family inside the
  # deadline, and how its time grew with the input.
  struct DeadlineVerdict
    include JSON::Serializable

    getter engine : String
    getter family : String
    getter deadline_ms : Int64
    getter sizes_run : Int32
    getter max_seconds : Float64
    # Every size returned a result or a named limit error within the
    # deadline (plus 10% and 5 ms of process noise).
    getter? within_deadline : Bool
    # Least-squares slope of log(time) over log(n), sizes n >= 1024 that
    # completed; about 1 means linear.
    getter growth_slope : Float64
    getter? linear : Bool
    getter verdict : String

    def initialize(*, @engine, @family, @deadline_ms, @sizes_run, @max_seconds, @within_deadline, @growth_slope,
                   @linear, @verdict)
    end
  end

  struct ReportDocument
    include JSON::Serializable

    getter run : RunRecord
    getter baseline_engine : String
    getter list_of_compared_engines : Array(String)
    getter status_counts : Hash(String, Hash(String, Int32))
    getter group_summaries : Array(GroupSummary)
    getter case_comparisons : Array(CaseComparison)
    getter slower_than_baseline : Array(CaseComparison)
    getter redos_rows : Array(RedosRow)
    getter deadline_verdicts : Array(DeadlineVerdict)
    getter rebar_count_disagreements : Array(String)

    def initialize(*, @run, @baseline_engine, @list_of_compared_engines, @status_counts, @group_summaries,
                   @case_comparisons, @slower_than_baseline, @redos_rows, @deadline_verdicts,
                   @rebar_count_disagreements)
    end
  end
end
