# Engine runner: `Mica::Regex.static` patterns from this checkout (the
# GC-free study). bench/regex/gc_study/write_static_patterns.rb writes the
# pattern table it compiles in; bench/regex/gc_study/run_study.sh builds it.
#   crystal-alpha build --release bench/regex/mica_static_runner.cr -o bench/bin/regex/mica_static_runner
require "../../src/mica"
require "./src/regex_bench"
require "./src/regex_bench/engines/mica_static_engine"
require "../data/regex/static_patterns"

RegexBench::RunnerProgram.new(RegexBench::MicaStaticEngine.new(RegexBench::StaticPatterns.table), ARGV, STDIN, STDOUT).run
