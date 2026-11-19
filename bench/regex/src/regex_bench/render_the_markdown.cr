module RegexBench
  # Number formatting shared by the report.
  module Report
    def self.format_seconds(seconds : Float64) : String
      if seconds <= 0
        "-"
      elsif seconds < 1e-6
        "#{(seconds * 1e9).round(1)} ns"
      elsif seconds < 1e-3
        "#{(seconds * 1e6).round(2)} µs"
      elsif seconds < 1.0
        "#{(seconds * 1e3).round(2)} ms"
      else
        "#{seconds.round(3)} s"
      end
    end

    def self.format_ratio(ratio : Float64) : String
      ratio > 0 ? "#{ratio.round(3)}x" : "-"
    end

    def self.format_bytes(bytes : Int64) : String
      if bytes >= 1_048_576
        "#{(bytes / 1_048_576.0).round(1)} MiB"
      elsif bytes >= 1024
        "#{(bytes / 1024.0).round(1)} KiB"
      else
        "#{bytes} B"
      end
    end

    def self.format_percent(fraction : Float64) : String
      "#{(fraction * 100).round(1)}%"
    end

    # A ratio with the two absolute times behind it: "0.5x (20.0 µs / 40.0 µs)",
    # engine first.
    def self.format_ratio_with_seconds(ratio : Float64, engine_seconds : Float64, baseline_seconds : Float64) : String
      return "-" unless ratio > 0
      "#{format_ratio(ratio)} (#{format_seconds(engine_seconds)} / #{format_seconds(baseline_seconds)})"
    end
  end

  # Writes a `ReportDocument` (and the raw results for the appendix) as
  # Markdown.
  class RenderTheMarkdown
    def initialize(@document : ReportDocument, @list_of_results : Array(CaseResult), @title : String)
    end

    def perform : String
      String.build do |io|
        write_summary(io)
        write_group_table(io)
        write_slower_cases(io)
        write_redos(io)
        write_deadline_suite(io)
        write_method(io)
        write_machine(io)
        write_disagreements(io)
        write_appendix(io)
      end
    end

    private def write_summary(io : IO) : Nil
      run = @document.run
      io << "# " << @title << "\n\n"
      io << "Run " << run.started_at << " to " << run.finished_at << ". Baseline: `"
      io << @document.baseline_engine << "` (Crystal stdlib `Regex`, PCRE2 with JIT). "
      io << "Every ratio is engine time / baseline time: below 1.0 the engine is faster.\n\n"
      io << "| Engine | Version | ok | limit | timeout | skipped | unsupported | pending | crashed |\n"
      io << "|---|---|---|---|---|---|---|---|---|\n"
      run.engines.each do |description|
        counts = @document.status_counts[description.engine]? || Hash(String, Int32).new(0)
        io << "| `" << description.engine << "` | " << description.version << " | "
        %w[ok limit timeout skipped unsupported pending crashed].each do |status|
          io << (counts[status]? || 0) << " | "
        end
        io << "\n"
      end
      io << "\n"
      @document.list_of_compared_engines.each do |engine|
        overall = @document.group_summaries.find { |summary| summary.engine == engine && summary.group == "all cases" }
        next unless overall
        if overall.eligible_count == 0
          io << "- `" << engine << "`: no eligible cases (" << pending_or_status(engine) << ").\n"
        else
          engine_seconds = overall.engine_seconds
          baseline_seconds = overall.baseline_seconds
          io << "- `" << engine << "` over " << overall.eligible_count << " eligible cases (geometric means, engine / baseline time in parentheses): warm search "
          io << Report.format_ratio_with_seconds(overall.primary_geometric_mean, engine_seconds.warm, baseline_seconds.warm) << ", compile "
          io << Report.format_ratio_with_seconds(overall.compile_geometric_mean, engine_seconds.compile, baseline_seconds.compile) << ", cold first search "
          io << Report.format_ratio_with_seconds(overall.cold_geometric_mean, engine_seconds.cold, baseline_seconds.cold) << ", process-cold "
          io << Report.format_ratio_with_seconds(overall.process_cold_geometric_mean, engine_seconds.process_cold, baseline_seconds.process_cold) << "; slower than the baseline on "
          io << overall.slower_count << " cases.\n"
        end
      end
      io << "\n"
    end

    private def pending_or_status(engine : String) : String
      description = @document.run.engines.find { |candidate| candidate.engine == engine }
      return description.pending_reason if description && !description.ready?
      "see the status table"
    end

    private def write_group_table(io : IO) : Nil
      io << "## Geometric means per group\n\n"
      io << "Ratio to `" << @document.baseline_engine << "` over each group's eligible cases (both engines finished and their counts agree). "
      io << "Warm search is the model's primary metric (compile time for rebar's `compile` model). "
      io << "Cold first search is compile plus one search in a process that has already run the case; process-cold is compile plus "
      io << "the first search as the first regex work of a fresh runner process. Beside each ratio: the geometric means of the "
      io << "engine's and the baseline's medians.\n\n"
      io << "| Engine | Group | Cases | Eligible | Warm search | Compile | Cold first search | Process-cold | Slower cases |\n"
      io << "|---|---|---|---|---|---|---|---|---|\n"
      @document.group_summaries.each do |summary|
        engine_seconds = summary.engine_seconds
        baseline_seconds = summary.baseline_seconds
        io << "| `" << summary.engine << "` | " << summary.group << " | " << summary.case_count << " | "
        io << summary.eligible_count << " | "
        io << Report.format_ratio_with_seconds(summary.primary_geometric_mean, engine_seconds.warm, baseline_seconds.warm) << " | "
        io << Report.format_ratio_with_seconds(summary.compile_geometric_mean, engine_seconds.compile, baseline_seconds.compile) << " | "
        io << Report.format_ratio_with_seconds(summary.cold_geometric_mean, engine_seconds.cold, baseline_seconds.cold) << " | "
        io << Report.format_ratio_with_seconds(summary.process_cold_geometric_mean, engine_seconds.process_cold, baseline_seconds.process_cold) << " | "
        io << summary.slower_count << " |\n"
      end
      io << "\n"
    end

    private def write_slower_cases(io : IO) : Nil
      io << "## Every case where Mica is slower than PCRE2-JIT\n\n"
      mica_slower = @document.slower_than_baseline.select { |comparison| comparison.engine == "mica" }
      mica_comparisons = @document.case_comparisons.select { |comparison| comparison.engine == "mica" }
      if mica_comparisons.empty?
        io << "Mica was not part of this run.\n\n"
      elsif mica_comparisons.none?(&.eligible?)
        io << "None measured: " << pending_or_status("mica") << ".\n\n"
      elsif mica_slower.empty?
        io << "None. Mica is as fast as or faster than PCRE2-JIT on every eligible case.\n\n"
      else
        io << "| Case | Model | Mica | PCRE2-JIT | Ratio | Margin | Batch (Mica / PCRE2-JIT) |\n"
        io << "|---|---|---|---|---|---|---|\n"
        mica_slower.each do |comparison|
          io << "| " << comparison.case_id << " | " << comparison.model << " | "
          io << Report.format_seconds(comparison.engine_primary_median_seconds) << " | "
          io << Report.format_seconds(comparison.baseline_primary_median_seconds) << " | "
          io << Report.format_ratio(comparison.primary_ratio) << " | +"
          io << Report.format_percent(comparison.primary_ratio - 1) << " | "
          io << comparison.engine_iterations_per_sample << " / " << comparison.baseline_iterations_per_sample << " |\n"
        end
        io << "\n"
      end
      other_engines = @document.list_of_compared_engines.reject { |engine| engine == "mica" }
      other_engines.each do |engine|
        count = @document.slower_than_baseline.count { |comparison| comparison.engine == engine }
        io << "`" << engine << "` is slower than PCRE2-JIT on " << count << " eligible cases (listed in the JSON report).\n\n"
      end
    end

    private def write_redos(io : IO) : Nil
      io << "## ReDoS set\n\n"
      io << "One search from the start of `prepend + unit * n + append`. A cell is the search time, the limit the engine stopped on "
      io << "and when, `timeout` when the driver stopped the process, or `skipped` after a smaller n timed out.\n\n"
      engines = @document.run.engines.map(&.engine)
      io << "| Family | Pattern | n | Bytes | " << engines.map { |engine| "`#{engine}`" }.join(" | ") << " |\n"
      io << "|---|---|---|---|" << engines.map { "---" }.join("|") << "|\n"
      @document.redos_rows.each do |row|
        io << "| " << row.family << " | `" << row.pattern.gsub('|', "\\|") << "` | " << row.size_units << " | "
        io << Report.format_bytes(row.haystack_bytes) << " | "
        engines.each do |engine|
          cell = row.cells.find { |candidate| candidate.engine == engine }
          io << (cell ? redos_cell_text(cell) : "-") << " | "
        end
        io << "\n"
      end
      io << "\n"
      losses = @document.redos_rows.flat_map do |row|
        row.cells.select { |cell| cell.engine.starts_with?("pcre2") && cell.counts_as_a_redos_loss? }.map { |cell| {row, cell} }
      end
      io << "PCRE2 hit a limit, ran longer than 1 s, or timed out on " << losses.size << " ReDoS runs.\n\n"
    end

    private def redos_cell_text(cell : RedosCell) : String
      case cell.status
      when "ok"    then "#{Report.format_seconds(cell.seconds)} (#{cell.matched? ? "match" : "no match"})"
      when "limit" then "#{cell.limit_name} after #{Report.format_seconds(cell.seconds)}"
      else              cell.status
      end
    end

    private def write_deadline_suite(io : IO) : Nil
      io << "## Deadline and budget suite\n\n"
      io << "Each ReDoS family must return a result or raise the engine's named limit error within the deadline at every n, "
      io << "and its time must grow linearly: the least-squares slope of log(time) over log(n), for completed sizes n >= "
      io << BuildTheReport::SLOPE_MIN_SIZE << ", must be at most " << BuildTheReport::LINEAR_SLOPE_CEILING << ". "
      io << "The gate is Mica's; the PCRE2 rows are the contrast (PCRE2 has no deadline).\n\n"
      io << "| Engine | Family | Deadline | Sizes | Slowest | Slope | Verdict |\n|---|---|---|---|---|---|---|\n"
      @document.deadline_verdicts.sort_by { |verdict| {verdict.engine, verdict.family} }.each do |verdict|
        io << "| `" << verdict.engine << "` | " << verdict.family << " | " << verdict.deadline_ms << " ms | "
        io << verdict.sizes_run << " | " << Report.format_seconds(verdict.max_seconds) << " | "
        io << (verdict.growth_slope > 0 ? verdict.growth_slope.round(2).to_s : "-") << " | " << verdict.verdict << " |\n"
      end
      io << "\n"
    end

    private def write_method(io : IO) : Nil
      run = @document.run
      io << "## Method\n\n"
      io << "- Each engine runs every case in its own process (separate linkage and memory); processes run one at a time.\n"
      io << "- Per case: the process-cold first compile + search is timed once; one full iteration verifies the count; "
      io << "then compile, cold first search (compile + one search, a new pattern each sample) and warm search are sampled.\n"
      io << "- Every timed cold and warm search gets its own String, equal to the haystack but a separate object, as a web app "
      io << "gets a new String per request; the copies for a batch are made before its clock starts, for every engine alike.\n"
      io << "- Warm search gets up to 3 warm-up iterations (0.5 s), then samples: at most " << run.max_samples
      io << ", at least " << run.min_samples << ", stopping once " << run.phase_seconds
      io << " s have passed; an iteration slower than 2 s is sampled once.\n"
      io << "- An operation shorter than " << Report.format_seconds(MeasurementSettings.new.min_batch_seconds)
      io << " is timed in calibrated batches, the same way for every engine: the batch doubles until two timed loops in a row each "
      io << "take at least that long, each sample times one batch and divides by its size (sampled again with a doubled "
      io << "batch while the median sample falls short), and the batch size is "
      io << "recorded per case and metric (`iterations_per_sample`; the slower-cases table shows the primary metric's). "
      io << "Longer operations are timed one at a time.\n"
      io << "- Reported: median with p25/p75 and min/max (relative spread = (p75 - p25) / median). Ratios use medians; "
      io << "group summaries use geometric means of ratios over eligible cases.\n"
      io << "- Peak memory: the process's peak RSS, and the part above the RSS right after the haystack was built.\n"
      io << "- Process caps: " << run.case_timeout_seconds << " s per throughput case, " << run.redos_timeout_seconds << " s per ReDoS case.\n\n"
    end

    private def write_machine(io : IO) : Nil
      run = @document.run
      io << "## Machine and toolchain\n\n"
      io << "- OS: " << run.operating_system << "\n"
      io << "- CPU: " << run.cpu << " (" << run.logical_cpu_count << " logical CPUs), memory " << Report.format_bytes(run.memory_bytes) << "\n"
      io << "- Crystal: " << run.crystal_version << "\n"
      run.engines.each { |description| io << "- `" << description.engine << "`: " << description.version << "\n" }
      io << "- Harness commit: " << run.harness_commit << "; Mica measured: " << run.mica_ref << " at " << run.mica_commit << "\n"
      io << "- rebar corpus: " << run.rebar_commit << ", tarball sha256 " << run.rebar_tarball_sha256 << "\n"
      io << "- Corpora: " << run.list_of_corpora.join(", ") << "\n\n"
    end

    private def write_disagreements(io : IO) : Nil
      io << "## Cases outside the comparison\n\n"
      unless @document.rebar_count_disagreements.empty?
        io << "rebar's expected count assumes PCRE2 without UTF/UCP when a benchmark disables Unicode; Crystal always compiles with "
        io << "UTF and UCP, so these counts differ. The baseline's own count is the reference for every engine.\n\n"
        @document.rebar_count_disagreements.each { |line| io << "- " << line << "\n" }
        io << "\n"
      end
      outside = @list_of_results.reject { |case_result| case_result.succeeded? || case_result.corpus == "redos" || case_result.status == "pending" }
      unless outside.empty?
        io << "| Engine | Case | Status | Detail |\n|---|---|---|---|\n"
        outside.each do |case_result|
          io << "| `" << case_result.engine << "` | " << case_result.case_id << " | " << case_result.status << " | "
          io << case_result.detail.gsub('|', "\\|").gsub('\n', ' ') << " |\n"
        end
        io << "\n"
      end
    end

    private def write_appendix(io : IO) : Nil
      io << "## Appendix: every case\n\n"
      engines = @document.list_of_compared_engines
      io << "| Case | Model | Bytes | PCRE2-JIT warm (spread) | JIT compile | JIT cold | JIT engine RSS | "
      io << engines.map { |engine| "`#{engine}` ratio" }.join(" | ") << " |\n"
      io << "|---|---|---|---|---|---|---|" << engines.map { "---" }.join("|") << "|\n"
      baseline_results = @list_of_results.select { |case_result| case_result.engine == @document.baseline_engine && case_result.corpus != "redos" }
      comparisons = @document.case_comparisons.to_h { |comparison| { {comparison.case_id, comparison.engine}, comparison } }
      baseline_results.each do |case_result|
        io << "| " << case_result.case_id << " | " << case_result.model << " | " << Report.format_bytes(case_result.haystack_bytes) << " | "
        if case_result.succeeded?
          primary = case_result.model == "compile" ? case_result.compile : case_result.warm_search
          io << Report.format_seconds(primary.median) << " (" << Report.format_percent(primary.relative_spread) << ") | "
          io << Report.format_seconds(case_result.compile.median) << " | " << Report.format_seconds(case_result.cold_first_search.median) << " | "
          io << Report.format_bytes(case_result.engine_rss_bytes) << " | "
        else
          io << case_result.status << " | - | - | - | "
        end
        engines.each do |engine|
          comparison = comparisons[{case_result.case_id, engine}]?
          io << (comparison ? (comparison.eligible? ? Report.format_ratio(comparison.primary_ratio) : comparison.status) : "-") << " | "
        end
        io << "\n"
      end
      io << "\n"
    end
  end
end
