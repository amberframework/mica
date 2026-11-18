# The driver: runs the selected cases in every selected engine's runner
# program and writes results.jsonl and run.json. bench/regex/run.sh builds
# and calls it; see docs/benchmarks.md.
require "option_parser"
require "./src/regex_bench"

runner_directory = File.expand_path("../bin/regex", __DIR__)
output_directory = File.expand_path("../data/regex/runs/latest", __DIR__)
corpus_directory = File.join(__DIR__, "corpus")
data_directory = File.expand_path("../data/regex", __DIR__)
list_of_engines = %w[pcre2-jit pcre2-interpreter mica]
list_of_corpora = RegexBench::Corpus::LIST_OF_CORPORA.dup
case_filter = ""
max_amber_bytes = Int64::MAX
max_samples = 11
min_samples = 3
phase_seconds = 1.0
case_timeout_seconds = 600.0
redos_timeout_seconds = 10.0
mica_ref = "working tree"
mica_commit = "unknown"
harness_commit = "unknown"

OptionParser.parse do |parser|
  parser.banner = "usage: run_cases [options]"
  parser.on("--runners DIR", "Directory holding the runner binaries") { |value| runner_directory = value }
  parser.on("--out DIR", "Directory for results.jsonl and run.json") { |value| output_directory = value }
  parser.on("--data DIR", "Data directory holding rebar-<commit>/ (default bench/data/regex)") { |value| data_directory = value }
  parser.on("--engines LIST", "Comma-separated engines (pcre2-jit is the baseline)") { |value| list_of_engines = value.split(',') }
  parser.on("--corpora LIST", "Comma-separated corpora: rebar, amber, redos") { |value| list_of_corpora = value.split(',') }
  parser.on("--only TEXT", "Run only cases whose id contains TEXT") { |value| case_filter = value }
  parser.on("--max-amber-bytes N", "Skip Amber haystacks larger than N bytes") { |value| max_amber_bytes = value.to_i64 }
  parser.on("--max-samples N", "Samples per measurement at most") { |value| max_samples = value.to_i }
  parser.on("--min-samples N", "Samples per measurement at least") { |value| min_samples = value.to_i }
  parser.on("--phase-seconds S", "Seconds a measurement may take once it has its minimum samples") { |value| phase_seconds = value.to_f }
  parser.on("--case-timeout S", "Process cap for a throughput case") { |value| case_timeout_seconds = value.to_f }
  parser.on("--redos-timeout S", "Process cap for a ReDoS case") { |value| redos_timeout_seconds = value.to_f }
  parser.on("--mica-ref REF", "Label of the Mica ref measured") { |value| mica_ref = value }
  parser.on("--mica-commit SHA", "Commit of the Mica ref measured") { |value| mica_commit = value }
  parser.on("--harness-commit SHA", "Commit of this harness") { |value| harness_commit = value }
end

unless list_of_engines.includes?("pcre2-jit")
  abort "the baseline engine pcre2-jit must be in --engines"
end

settings = RegexBench::DriverSettings.new(
  runner_directory: runner_directory, output_directory: output_directory, corpus_directory: corpus_directory,
  data_directory: data_directory, list_of_engines: list_of_engines,
  list_of_corpora: list_of_corpora, case_filter: case_filter, max_amber_bytes: max_amber_bytes,
  max_samples: max_samples, min_samples: min_samples, phase_seconds: phase_seconds,
  case_timeout_seconds: case_timeout_seconds, redos_timeout_seconds: redos_timeout_seconds,
  mica_ref: mica_ref, mica_commit: mica_commit, harness_commit: harness_commit)
RegexBench::RunCasesAgainstEngines.new(settings, STDERR).perform
