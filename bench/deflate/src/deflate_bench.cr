# The harness both Inflate benchmark runners are built from (docs/benchmarks.md,
# "Inflate"). A runner program registers its engines and hands ARGV to
# `DeflateBench::RunTheRunner`.
require "./deflate_bench/errors"
require "./deflate_bench/format"
require "./deflate_bench/engine"
require "./deflate_bench/measurement"
require "./deflate_bench/measure_one_case"
require "./deflate_bench/decode_once_for_peak_memory"
require "./deflate_bench/run_the_runner"
