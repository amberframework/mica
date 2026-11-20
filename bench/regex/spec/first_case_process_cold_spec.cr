require "file_utils"
require "./spec_helper"

# An integration spec over the release runner binaries. Build them with
# bench/regex/run.sh (or crystal-alpha build --release), fetch the rebar
# corpus with bench/regex/scripts/rebar_corpus.rb, then:
#
#   REGEX_BENCH_RUNNERS=bench/bin/regex crystal-alpha spec bench/regex/spec/first_case_process_cold_spec.cr
#
# Without REGEX_BENCH_RUNNERS the example is pending. It writes the samples
# it compared to bench/data/regex/spec-runs/<id>/first_case_process_cold.json.

private FIRST_CASE_ID        = "captures/contiguous-letters"
private ROUNDS               = 9
private PROCESS_COLD_SAMPLES = 3
private LIST_OF_ENGINES      = {"pcre2-jit" => "pcre2_jit_runner", "mica" => "mica_runner"}

# What one engine measured over the rounds. Round i pairs a run on a
# never-touched copy of the runners (the case is the first regex work that
# copy does) with a standalone run on a copy that has run the case before.
private record EngineComparison, engine : String,
  list_of_first_case_seconds : Array(Float64), list_of_first_sample_seconds : Array(Float64),
  list_of_standalone_seconds : Array(Float64), list_of_standalone_samples : Array(Float64),
  interval : RegexBench::RatioInterval, outlier_fence_seconds : Float64, unwarmed_seconds : Float64 do
  include JSON::Serializable
end

private def bench_directory(relative : String) : String
  File.expand_path(relative, "#{__DIR__}/..")
end

# Copies the runners into a new directory: new files, whose pages no
# process has touched yet, as right after a build. `cp` clones the file on
# APFS, so its pages start outside the page cache, as a linker's output
# does in a full run (File.copy would write them through the cache).
private def fresh_copy_of_runners(source : String, destination : String) : Nil
  Dir.mkdir_p(destination)
  LIST_OF_ENGINES.each_value do |binary|
    path = File.join(source, binary)
    next unless File.exists?(path)
    status = Process.run("cp", [path, File.join(destination, binary)])
    raise RegexBench::Error.new("could not copy #{path}") unless status.success?
  end
end

private def run_the_driver(runner_directory : String, output_directory : String, list_of_engines : Array(String),
                           process_cold_samples : Int32) : Hash(String, RegexBench::CaseResult)
  settings = RegexBench::DriverSettings.new(
    runner_directory: runner_directory, output_directory: output_directory,
    corpus_directory: bench_directory("corpus"), data_directory: bench_directory("../data/regex"),
    list_of_engines: list_of_engines, list_of_corpora: ["rebar"], case_filter: FIRST_CASE_ID,
    max_amber_bytes: 0_i64, max_samples: 3, min_samples: 1, phase_seconds: 0.1, case_timeout_seconds: 600.0,
    redos_timeout_seconds: 10.0, process_cold_samples: process_cold_samples, case_order_seed: 1_u64,
    mica_ref: "spec", mica_commit: "spec", harness_commit: "spec")
  RegexBench::RunCasesAgainstEngines.new(settings, IO::Memory.new).perform
  File.read_lines(File.join(output_directory, "results.jsonl"))
    .reject(&.blank?)
    .map { |line| RegexBench::CaseResult.from_json(line) }
    .to_h { |case_result| {case_result.engine, case_result} }
end

# One `--process-cold` process on a never-touched copy of the runner, with
# no page-in first: the condition the first case of a run used to meet.
private def unwarmed_process_cold_seconds(runner_directory : String, binary : String) : Float64
  corpus = RegexBench::Corpus.new(bench_directory("corpus"), bench_directory("../data/regex"))
  benchmark_case = corpus.cases_for(["rebar"]).find { |candidate| candidate.id == FIRST_CASE_ID }
  raise RegexBench::CorpusError.new("no #{FIRST_CASE_ID} in the rebar corpus") unless benchmark_case
  outcome = RegexBench::RunOneRunnerProcess.new(File.join(runner_directory, binary),
    ["--rebar-haystacks", corpus.rebar_haystack_directory, "--process-cold"], benchmark_case.to_json, 600.0).perform
  line = outcome.standard_output.lines.last? || raise RegexBench::Error.new("no sample: #{outcome.standard_error}")
  RegexBench::ProcessColdSample.from_json(line).seconds
end

describe RegexBench::RunCasesAgainstEngines do
  describe "#perform" do
    it "gives the first case a runner binary meets the process-cold time it measures standalone" do
      source = ENV["REGEX_BENCH_RUNNERS"]?
      pending!("set REGEX_BENCH_RUNNERS to a directory of release runner binaries") unless source
      list_of_engines = LIST_OF_ENGINES.select { |_, binary| File.exists?(File.join(source, binary)) }.keys
      pending!("no runner binaries in #{source}") if list_of_engines.empty?

      run_directory = bench_directory("../data/regex/spec-runs/#{Time.utc.to_unix}-#{Random::Secure.hex(4)}")
      standalone_runners = File.join(run_directory, "standalone-runners")
      unwarmed_runners = File.join(run_directory, "unwarmed-runners")
      fresh_copy_of_runners(source, standalone_runners)
      fresh_copy_of_runners(source, unwarmed_runners)
      begin
        # Brings the standalone copy's pages in once, as earlier runs did
        # when the case was measured on its own.
        run_the_driver(standalone_runners, File.join(run_directory, "standalone-warm-up"), list_of_engines, 1)
        list_of_first_runs = [] of Hash(String, RegexBench::CaseResult)
        list_of_standalone_runs = [] of Hash(String, RegexBench::CaseResult)
        ROUNDS.times do |round|
          first_runners = File.join(run_directory, "first-runners-#{round}")
          fresh_copy_of_runners(source, first_runners)
          list_of_first_runs << run_the_driver(first_runners, File.join(run_directory, "first-#{round}"), list_of_engines, PROCESS_COLD_SAMPLES)
          FileUtils.rm_rf(first_runners)
          list_of_standalone_runs << run_the_driver(standalone_runners, File.join(run_directory, "standalone-#{round}"),
            list_of_engines, PROCESS_COLD_SAMPLES)
        end

        list_of_comparisons = list_of_engines.map do |engine|
          list_of_first_runs.each { |first_run| first_run[engine].status.should eq("ok") }
          list_of_first_case_seconds = list_of_first_runs.map(&.[engine].process_cold_seconds)
          list_of_standalone_seconds = list_of_standalone_runs.map(&.[engine].process_cold_seconds)
          list_of_standalone_samples = list_of_standalone_runs.flat_map(&.[engine].list_of_process_cold_seconds)
          quartiles = RegexBench::Statistics.of(list_of_standalone_samples)
          EngineComparison.new(engine: engine, list_of_first_case_seconds: list_of_first_case_seconds,
            list_of_first_sample_seconds: list_of_first_runs.map(&.[engine].process_first_search_seconds),
            list_of_standalone_seconds: list_of_standalone_seconds, list_of_standalone_samples: list_of_standalone_samples,
            interval: RegexBench::Statistics.paired_ratio_interval(list_of_first_case_seconds, list_of_standalone_seconds,
              confidence: 0.99),
            outlier_fence_seconds: quartiles.p75 + 3 * (quartiles.p75 - quartiles.p25),
            unwarmed_seconds: unwarmed_process_cold_seconds(unwarmed_runners, LIST_OF_ENGINES[engine]))
        end
        File.write(File.join(run_directory, "first_case_process_cold.json"), list_of_comparisons.to_pretty_json)

        list_of_comparisons.each do |comparison|
          interval = comparison.interval
          unless interval.includes?(1.0)
            fail "#{comparison.engine}: first-case/standalone process-cold #{interval.ratio.round(3)}x " \
                 "[#{interval.low.round(3)}, #{interval.high.round(3)}] (99%) excludes 1"
          end
          # The very first timed regex work of each never-touched copy, the
          # sample the old harness reported alone, stays inside Tukey's
          # far-out fence of the standalone samples.
          RegexBench::Statistics.of(comparison.list_of_first_sample_seconds).median.should be <= comparison.outlier_fence_seconds
        end

        # The control: without the page-in, a never-touched Mica binary is
        # still slow on its first case, so the comparison above can tell.
        {% if flag?(:darwin) %}
          if mica = list_of_comparisons.find { |comparison| comparison.engine == "mica" }
            mica.unwarmed_seconds.should be > mica.outlier_fence_seconds
          end
        {% end %}
      ensure
        FileUtils.rm_rf(Dir.glob(File.join(run_directory, "*-runners*")))
      end
    end
  end
end
