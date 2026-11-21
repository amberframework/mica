# Engine runner: `Mica::Regex.static` patterns from this checkout.
# bench/regex/scripts/write_static_patterns.rb writes the pattern table it
# compiles in; bench/regex/run.sh writes it and builds this runner when
# --engines names mica-static.
#   crystal-alpha build --release bench/regex/mica_static_runner.cr -o bench/bin/regex/mica_static_runner
require "../../src/mica"
require "./src/regex_bench"
require "./src/regex_bench/engines/mica_static_engine"
require "../data/regex/static_patterns"

RegexBench::RunnerProgram.new(RegexBench::MicaStaticEngine.new, ARGV, STDIN, STDOUT).run
