require "json"

module RegexBench
  # Settings of one driver run, from the driver's command line.
  record DriverSettings,
    runner_directory : String,
    output_directory : String,
    corpus_directory : String,
    data_directory : String,
    list_of_engines : Array(String),
    list_of_corpora : Array(String),
    case_filter : String,
    max_amber_bytes : Int64,
    max_samples : Int32,
    min_samples : Int32,
    phase_seconds : Float64,
    case_timeout_seconds : Float64,
    redos_timeout_seconds : Float64,
    process_cold_samples : Int32,
    case_order_seed : UInt64,
    mica_ref : String,
    mica_commit : String,
    harness_commit : String

  # When the driver is started, then it runs every selected case, in an
  # order shuffled by the recorded seed, in a fresh process of each selected
  # engine (engines in a shuffled order per case), one process at a time,
  # then takes the case's process-cold samples: rounds of one fresh
  # `--process-cold` process per engine. Every timed runner process starts
  # right after an untimed `--page-in` process of the same runner binary,
  # identical for every engine, so the once-per-binary cost of bringing its
  # pages in lands on no case. It stops a process that passes its time cap,
  # skips the larger sizes of a ReDoS family once a smaller one timed out,
  # and appends each `CaseResult` to results.jsonl beside a run.json
  # describing the machine and toolchain.
  class RunCasesAgainstEngines
    RUNNER_BINARIES = {
      "pcre2-jit"         => "pcre2_jit_runner",
      "pcre2-interpreter" => "pcre2_interpreter_runner",
      "mica"              => "mica_runner",
    }

    def initialize(@settings : DriverSettings, @progress : IO)
      @corpus = Corpus.new(@settings.corpus_directory, @settings.data_directory)
      @timed_out_families = Set(Tuple(String, String)).new
      @random = Random::PCG32.new(@settings.case_order_seed)
    end

    def perform : Nil
      Dir.mkdir_p(@settings.output_directory)
      list_of_descriptions = @settings.list_of_engines.map { |engine| describe(engine) }
      record = build_run_record(list_of_descriptions)
      list_of_cases = OrderCasesAtRandom.new(selected_cases, @settings.case_order_seed).perform
      @progress.puts "#{list_of_cases.size} cases x #{@settings.list_of_engines.size} engines, case order seed #{@settings.case_order_seed} -> #{@settings.output_directory}"

      File.open(File.join(@settings.output_directory, "results.jsonl"), "w") do |results|
        list_of_cases.each_with_index do |benchmark_case, index|
          run_the_case(benchmark_case).each do |case_result|
            case_result.to_json(results)
            results.puts
            results.flush
            @progress.puts "[#{index + 1}/#{list_of_cases.size}] #{case_result.engine} #{benchmark_case.id}: #{case_result.status} #{summary_of(case_result)}"
            @progress.flush
          end
        end
      end
      File.write(File.join(@settings.output_directory, "run.json"), record.finished(at: Time.utc).to_pretty_json)
    end

    private def selected_cases : Array(BenchmarkCase)
      @corpus.cases_for(@settings.list_of_corpora).select do |benchmark_case|
        next false unless @settings.case_filter.empty? || benchmark_case.id.includes?(@settings.case_filter)
        benchmark_case.corpus != "amber" || benchmark_case.size_units <= @settings.max_amber_bytes
      end
    end

    # Runs *benchmark_case* in every engine, then adds the process-cold
    # samples to each result that finished.
    private def run_the_case(benchmark_case : BenchmarkCase) : Array(CaseResult)
      list_of_results = @settings.list_of_engines.shuffle(@random).map { |engine| run_one(engine, benchmark_case) }
      samples_by_engine = take_process_cold_samples(benchmark_case, list_of_results)
      list_of_results.map do |case_result|
        list_of_seconds = samples_by_engine[case_result.engine]?
        if list_of_seconds && !list_of_seconds.empty?
          case_result.with_process_cold(list_of_seconds)
        elsif case_result.succeeded?
          case_result.with_process_cold([case_result.process_first_search_seconds])
        else
          case_result
        end
      end
    end

    # Takes `process_cold_samples` rounds; each round runs one fresh
    # `--process-cold` process per engine, in a shuffled order. An engine
    # whose first search took longer than the slow-iteration cap keeps its
    # single in-process sample, as `MeasureACase` does for cold search.
    private def take_process_cold_samples(benchmark_case : BenchmarkCase,
                                          list_of_results : Array(CaseResult)) : Hash(String, Array(Float64))
      slow_seconds = MeasurementSettings.new.slow_iteration_seconds
      list_of_sampled_engines = list_of_results.select { |case_result|
        case_result.succeeded? && case_result.process_first_search_seconds < slow_seconds
      }.map(&.engine)
      samples_by_engine = Hash(String, Array(Float64)).new { |hash, engine| hash[engine] = [] of Float64 }
      @settings.process_cold_samples.times do
        list_of_sampled_engines.shuffle(@random).each do |engine|
          if seconds = process_cold_seconds(engine, benchmark_case)
            samples_by_engine[engine] << seconds
          end
        end
      end
      samples_by_engine
    end

    private def process_cold_seconds(engine : String, benchmark_case : BenchmarkCase) : Float64?
      page_in(engine)
      outcome = RunOneRunnerProcess.new(runner_path(engine), process_cold_arguments, benchmark_case.to_json,
        timeout_for(benchmark_case)).perform
      line = outcome.standard_output.lines.last?
      return if outcome.timed_out? || line.nil?
      sample = ProcessColdSample.from_json(line)
      sample.seconds if sample.succeeded?
    rescue JSON::ParseException
      nil
    end

    # Runs the engine's runner once with `--page-in`, untimed: no regex
    # work, only its own pages brought in (see `PageInTheRunnerImage`).
    private def page_in(engine : String) : Nil
      outcome = RunOneRunnerProcess.new(runner_path(engine), ["--page-in"], "", 60.0).perform
      line = outcome.standard_output.lines.last?
      raise Error.new("#{engine} runner did not page itself in: #{outcome.standard_error}") unless line
      begin
        PageInSummary.from_json(line)
      rescue JSON::ParseException
        raise Error.new("#{engine} runner wrote no page-in summary: #{outcome.standard_error}")
      end
    end

    private def run_one(engine : String, benchmark_case : BenchmarkCase) : CaseResult
      family_key = {engine, benchmark_case.family}
      if benchmark_case.belongs_to_the_redos_set? && @timed_out_families.includes?(family_key)
        return CaseResult.new(benchmark_case: benchmark_case, engine: engine, status: "skipped",
          detail: "a smaller size of this family timed out")
      end

      timeout = timeout_for(benchmark_case)
      page_in(engine)
      outcome = RunOneRunnerProcess.new(runner_path(engine), runner_arguments, benchmark_case.to_json, timeout).perform
      if outcome.timed_out?
        @timed_out_families << family_key if benchmark_case.belongs_to_the_redos_set?
        return CaseResult.new(benchmark_case: benchmark_case, engine: engine, status: "timeout",
          detail: "stopped after #{timeout} s")
      end
      parse_result(engine, benchmark_case, outcome)
    end

    private def parse_result(engine : String, benchmark_case : BenchmarkCase, outcome : RunnerOutcome) : CaseResult
      line = outcome.standard_output.lines.last?
      return crashed(engine, benchmark_case, outcome) unless line
      CaseResult.from_json(line)
    rescue JSON::ParseException
      crashed(engine, benchmark_case, outcome)
    end

    private def crashed(engine : String, benchmark_case : BenchmarkCase, outcome : RunnerOutcome) : CaseResult
      error_tail = outcome.standard_error.lines.last(3).join(" | ")
      CaseResult.new(benchmark_case: benchmark_case, engine: engine, status: "crashed",
        detail: "exit #{outcome.exit_description}: #{error_tail}")
    end

    private def runner_path(engine : String) : String
      binary = RUNNER_BINARIES[engine]? || raise Error.new("unknown engine #{engine}; expected one of #{RUNNER_BINARIES.keys.join(", ")}")
      File.join(@settings.runner_directory, binary)
    end

    private def runner_arguments : Array(String)
      ["--rebar-haystacks", @corpus.rebar_haystack_directory,
       "--max-samples", @settings.max_samples.to_s,
       "--min-samples", @settings.min_samples.to_s,
       "--phase-seconds", @settings.phase_seconds.to_s]
    end

    private def timeout_for(benchmark_case : BenchmarkCase) : Float64
      benchmark_case.belongs_to_the_redos_set? ? @settings.redos_timeout_seconds : @settings.case_timeout_seconds
    end

    private def process_cold_arguments : Array(String)
      ["--rebar-haystacks", @corpus.rebar_haystack_directory, "--process-cold"]
    end

    private def describe(engine : String) : EngineDescription
      outcome = RunOneRunnerProcess.new(runner_path(engine), ["--describe"], "", 60.0).perform
      line = outcome.standard_output.lines.last? || raise Error.new("#{engine} runner did not describe itself: #{outcome.standard_error}")
      EngineDescription.from_json(line)
    end

    private def summary_of(case_result : CaseResult) : String
      return case_result.detail unless case_result.succeeded?
      "warm #{(case_result.warm_search.median * 1000).round(3)} ms, compile #{(case_result.compile.median * 1_000_000).round(1)} us, " \
      "process-cold #{(case_result.process_cold_seconds * 1_000_000).round(1)} us, count #{case_result.count}"
    end

    private def build_run_record(list_of_descriptions : Array(EngineDescription)) : RunRecord
      rebar_source = @corpus.rebar_pin
      RunRecord.new(
        started_at: Time.utc.to_rfc3339,
        operating_system: command_output("uname", ["-srm"]),
        cpu: cpu_name,
        logical_cpu_count: System.cpu_count.to_i32,
        memory_bytes: memory_bytes,
        crystal_version: command_output("crystal-alpha", ["--version"]).gsub('\n', "; "),
        harness_commit: @settings.harness_commit,
        mica_ref: @settings.mica_ref,
        mica_commit: @settings.mica_commit,
        rebar_commit: rebar_source.commit,
        rebar_tarball_sha256: rebar_source.tarball_sha256,
        list_of_corpora: @settings.list_of_corpora,
        max_samples: @settings.max_samples,
        min_samples: @settings.min_samples,
        phase_seconds: @settings.phase_seconds,
        case_timeout_seconds: @settings.case_timeout_seconds,
        redos_timeout_seconds: @settings.redos_timeout_seconds,
        engines: list_of_descriptions,
        case_order_seed: @settings.case_order_seed,
        process_cold_samples: @settings.process_cold_samples)
    end

    private def cpu_name : String
      {% if flag?(:darwin) %}
        command_output("sysctl", ["-n", "machdep.cpu.brand_string"])
      {% else %}
        model_line = File.read_lines("/proc/cpuinfo").find(&.starts_with?("model name")) || "model name: unknown"
        model_line.partition(':').last.strip
      {% end %}
    end

    private def memory_bytes : Int64
      {% if flag?(:darwin) %}
        command_output("sysctl", ["-n", "hw.memsize"]).to_i64? || 0_i64
      {% else %}
        total_line = File.read_lines("/proc/meminfo").find(&.starts_with?("MemTotal")) || "MemTotal: 0 kB"
        (total_line.split[1].to_i64? || 0_i64) * 1024
      {% end %}
    end

    private def command_output(command : String, list_of_arguments : Array(String)) : String
      output = IO::Memory.new
      Process.run(command, list_of_arguments, output: output, error: Process::Redirect::Close)
      output.to_s.strip
    rescue File::NotFoundError | IO::Error
      "unknown"
    end
  end
end
