# The Mica runner's program body. Require Mica before this file: the
# adapter checks at compile time whether `Mica::Regex.compile` exists.
require "./regex_bench"
require "./regex_bench/engines/mica_engine"

RegexBench::RunnerProgram.new(RegexBench.build_mica_engine, ARGV, STDIN, STDOUT).run
