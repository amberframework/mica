# Engine runner: Crystal's stdlib Regex (PCRE2 with JIT), the baseline.
#   crystal-alpha build --release bench/regex/pcre2_jit_runner.cr -o bench/bin/regex/pcre2_jit_runner
require "./src/regex_bench"
require "./src/regex_bench/engines/pcre2_limit_name"
require "./src/regex_bench/engines/pcre2_jit_engine"

RegexBench::RunnerProgram.new(RegexBench::Pcre2JitEngine.new, ARGV, STDIN, STDOUT).run
