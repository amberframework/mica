# Engine runner: PCRE2's interpreter through a direct binding (no JIT).
#   crystal-alpha build --release bench/regex/pcre2_interpreter_runner.cr -o bench/bin/regex/pcre2_interpreter_runner
require "./src/regex_bench"
require "./src/regex_bench/engines/pcre2_limit_name"
require "./src/regex_bench/engines/pcre2_interpreter_engine"

RegexBench::RunnerProgram.new(RegexBench::Pcre2InterpreterEngine.new, ARGV, STDIN, STDOUT).run
