module RegexBench
  # When a run's results are in, then every engine's case is compared with
  # the baseline's, the ratios are summarized per group by geometric mean,
  # the cases where an engine is slower are listed with their margin, and
  # the ReDoS results are laid out by family and size and judged against
  # the deadline.
  class BuildTheReport
    BASELINE_ENGINE      = "pcre2-jit"
    GATED_ENGINE         = "mica"
    LINEAR_SLOPE_CEILING =      1.3
    SLOPE_MIN_SIZE       = 1024_i64

    def initialize(@run : RunRecord, @list_of_results : Array(CaseResult), @list_of_redos_families : Array(Corpus::RedosFamily))
      @results_by_case = Hash(String, Hash(String, CaseResult)).new
      @list_of_case_ids = [] of String
      @list_of_results.each do |case_result|
        @list_of_case_ids << case_result.case_id unless @results_by_case.has_key?(case_result.case_id)
        by_engine = @results_by_case[case_result.case_id] ||= Hash(String, CaseResult).new
        by_engine[case_result.engine] = case_result
      end
    end

    def perform : ReportDocument
      comparisons = list_of_compared_engines.flat_map { |engine| compare(engine) }
      ReportDocument.new(
        run: @run,
        baseline_engine: BASELINE_ENGINE,
        list_of_compared_engines: list_of_compared_engines,
        status_counts: status_counts,
        group_summaries: summarize(comparisons),
        case_comparisons: comparisons,
        slower_than_baseline: comparisons.select(&.slower_than_the_baseline?).sort_by { |comparison| -comparison.primary_ratio },
        redos_rows: redos_rows,
        deadline_verdicts: deadline_verdicts,
        rebar_count_disagreements: rebar_count_disagreements)
    end

    def list_of_engines : Array(String)
      @list_of_results.map(&.engine).uniq
    end

    def list_of_compared_engines : Array(String)
      list_of_engines.reject { |engine| engine == BASELINE_ENGINE }
    end

    private def compare(engine : String) : Array(CaseComparison)
      @list_of_case_ids.compact_map do |case_id|
        by_engine = @results_by_case[case_id]
        engine_result = by_engine[engine]?
        baseline = by_engine[BASELINE_ENGINE]?
        next unless engine_result && baseline
        build_comparison(engine_result, baseline)
      end
    end

    private def build_comparison(engine_result : CaseResult, baseline : CaseResult) : CaseComparison
      both_finished = engine_result.succeeded? && baseline.succeeded?
      counts_agree = engine_result.count == baseline.count
      eligible = both_finished && counts_agree && baseline.primary_median > 0
      detail = if !both_finished
                 "#{engine_result.status}#{engine_result.detail.empty? ? "" : ": #{engine_result.detail}"}"
               elsif !counts_agree
                 "count mismatch: #{engine_result.count} vs baseline #{baseline.count}"
               else
                 ""
               end
      CaseComparison.new(
        case_id: engine_result.case_id, group: engine_result.group, subgroup: engine_result.subgroup,
        model: engine_result.model, engine: engine_result.engine, status: engine_result.status,
        baseline_status: baseline.status, eligible: eligible, detail: detail,
        primary_ratio: eligible ? ratio(engine_result.primary_median, baseline.primary_median) : 0.0,
        compile_ratio: eligible ? ratio(engine_result.compile.median, baseline.compile.median) : 0.0,
        cold_ratio: eligible ? ratio(engine_result.cold_first_search.median, baseline.cold_first_search.median) : 0.0,
        process_cold_ratio: eligible ? ratio(engine_result.process_first_search_seconds, baseline.process_first_search_seconds) : 0.0,
        engine_seconds: metric_seconds(engine_result), baseline_seconds: metric_seconds(baseline),
        baseline_primary_median_seconds: baseline.primary_median,
        engine_primary_median_seconds: engine_result.primary_median,
        baseline_relative_spread: primary_statistics(baseline).relative_spread,
        engine_relative_spread: primary_statistics(engine_result).relative_spread,
        count: engine_result.count, baseline_count: baseline.count,
        engine_iterations_per_sample: primary_statistics(engine_result).iterations_per_sample,
        baseline_iterations_per_sample: primary_statistics(baseline).iterations_per_sample)
    end

    private def metric_seconds(case_result : CaseResult) : MetricSeconds
      MetricSeconds.new(warm: case_result.primary_median, compile: case_result.compile.median,
        cold: case_result.cold_first_search.median, process_cold: case_result.process_first_search_seconds)
    end

    private def primary_statistics(case_result : CaseResult) : Statistics
      case_result.model == "compile" ? case_result.compile : case_result.warm_search
    end

    private def ratio(value : Float64, baseline_value : Float64) : Float64
      baseline_value > 0 && value > 0 ? value / baseline_value : 0.0
    end

    private def summarize(comparisons : Array(CaseComparison)) : Array(GroupSummary)
      list_of_summaries = [] of GroupSummary
      comparisons.group_by(&.engine).each do |engine, engine_comparisons|
        by_corpus = engine_comparisons.group_by { |comparison| comparison.group.split('/').first }
        by_corpus.each do |corpus, corpus_comparisons|
          corpus_comparisons.group_by(&.group).each do |group, group_comparisons|
            list_of_summaries << summary_of(engine, group, group_comparisons)
          end
          list_of_summaries << summary_of(engine, "#{corpus} (all)", corpus_comparisons)
        end
        list_of_summaries << summary_of(engine, "all cases", engine_comparisons)
      end
      list_of_summaries
    end

    private def summary_of(engine : String, group : String, comparisons : Array(CaseComparison)) : GroupSummary
      eligible = comparisons.select(&.eligible?)
      GroupSummary.new(
        engine: engine, group: group, case_count: comparisons.size, eligible_count: eligible.size,
        primary_geometric_mean: Statistics.geometric_mean(eligible.map(&.primary_ratio).select(&.> 0)),
        compile_geometric_mean: Statistics.geometric_mean(eligible.map(&.compile_ratio).select(&.> 0)),
        cold_geometric_mean: Statistics.geometric_mean(eligible.map(&.cold_ratio).select(&.> 0)),
        process_cold_geometric_mean: Statistics.geometric_mean(eligible.map(&.process_cold_ratio).select(&.> 0)),
        engine_seconds: MetricSeconds.geometric_means(eligible.map(&.engine_seconds)),
        baseline_seconds: MetricSeconds.geometric_means(eligible.map(&.baseline_seconds)),
        slower_count: eligible.count(&.slower_than_the_baseline?))
    end

    private def status_counts : Hash(String, Hash(String, Int32))
      counts = Hash(String, Hash(String, Int32)).new
      @list_of_results.each do |case_result|
        by_status = counts[case_result.engine] ||= Hash(String, Int32).new(0)
        by_status[case_result.status] += 1
      end
      counts
    end

    private def redos_results : Array(CaseResult)
      @list_of_results.select { |case_result| case_result.corpus == "redos" }
    end

    private def redos_rows : Array(RedosRow)
      patterns = @list_of_redos_families.to_h { |family| {family.name, family.pattern} }
      order = @list_of_redos_families.map(&.name)
      redos_results.group_by { |case_result| {case_result.family, case_result.size_units} }
        .to_a
        .sort_by { |(key, _)| {order.index(key[0]) || order.size, key[1]} }
        .map do |(key, list_for_size)|
          RedosRow.new(
            family: key[0], pattern: patterns[key[0]]? || "", size_units: key[1],
            haystack_bytes: list_for_size.max_of(&.haystack_bytes),
            cells: list_for_size.map do |case_result|
              RedosCell.new(engine: case_result.engine, status: case_result.status,
                seconds: case_result.search_seconds, limit_name: case_result.limit_name,
                matched: case_result.count == 1)
            end)
        end
    end

    private def deadline_verdicts : Array(DeadlineVerdict)
      redos_results.group_by { |case_result| {case_result.engine, case_result.family} }.map do |(key, list_for_family)|
        verdict_for(key[0], key[1], list_for_family.sort_by(&.size_units))
      end
    end

    private def verdict_for(engine : String, family : String, list_for_family : Array(CaseResult)) : DeadlineVerdict
      deadline_ms = list_for_family.first.deadline_ms
      allowance = deadline_ms / 1000.0 * 1.1 + 0.005
      if list_for_family.all? { |case_result| case_result.status == "pending" }
        return DeadlineVerdict.new(engine: engine, family: family, deadline_ms: deadline_ms, sizes_run: 0,
          max_seconds: 0.0, within_deadline: false, growth_slope: 0.0, linear: false, verdict: "pending")
      end

      late = list_for_family.find do |case_result|
        finished = case_result.succeeded? || case_result.stopped_on_a_limit?
        !finished || case_result.search_seconds > allowance
      end
      completed = list_for_family.select { |case_result| case_result.succeeded? && case_result.size_units >= SLOPE_MIN_SIZE }
      points = completed.compact_map do |case_result|
        seconds = case_result.search_seconds
        {case_result.size_units.to_f, seconds} if seconds > 0
      end
      slope = Statistics.log_log_slope(points)
      linear = points.size < 2 || slope <= LINEAR_SLOPE_CEILING
      verdict = if engine != GATED_ENGINE
                  contrast_verdict(list_for_family)
                elsif late
                  "fail: n=#{late.size_units} #{late.status} after #{Report.format_seconds(late.search_seconds)}"
                elsif !linear
                  "fail: time grows as n^#{slope.round(2)}"
                else
                  "pass"
                end
      DeadlineVerdict.new(engine: engine, family: family, deadline_ms: deadline_ms, sizes_run: list_for_family.size,
        max_seconds: list_for_family.max_of(&.search_seconds), within_deadline: late.nil?,
        growth_slope: slope, linear: linear, verdict: verdict)
    end

    # PCRE2 has no deadline and its match limit is not a work budget over
    # the whole search, so its rows only describe what happened.
    private def contrast_verdict(list_for_family : Array(CaseResult)) : String
      tally = list_for_family.map(&.status).tally
      parts = %w[ok limit timeout skipped].compact_map { |status| "#{tally[status]} #{status}" if tally[status]? }
      "contrast, no deadline: #{parts.join(", ")}"
    end

    private def rebar_count_disagreements : Array(String)
      @list_of_results.compact_map do |case_result|
        next unless case_result.engine == BASELINE_ENGINE && case_result.succeeded?
        next unless case_result.expected_count >= 0 && case_result.count != case_result.expected_count
        "#{case_result.case_id}: Crystal PCRE2 counts #{case_result.count}, rebar expects #{case_result.expected_count}"
      end
    end
  end
end
