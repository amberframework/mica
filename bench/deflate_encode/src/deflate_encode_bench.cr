# The harness both Deflate encoder benchmark runners are built from
# (docs/benchmarks.md, "Deflate encoders"). A runner program registers its
# engines and hands ARGV to `DeflateEncodeBench::RunTheRunner`. Errors are
# shared with the Inflate harness (bench/deflate).
require "../../deflate/src/deflate_bench/errors"
require "./deflate_encode_bench/engine"
require "./deflate_encode_bench/measurement"
require "./deflate_encode_bench/measure_one_case"
require "./deflate_encode_bench/encode_once_for_peak_memory"
require "./deflate_encode_bench/run_the_runner"
