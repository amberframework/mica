# The regex benchmark harness: shared code for the engine runner programs,
# the driver that runs them, and the report writer.
#
# Nothing required here references stdlib `Regex`, so the Mica runner links
# no PCRE2. Each PCRE2 engine is required only by its own runner program.
module RegexBench
end

require "./regex_bench/errors"
require "./regex_bench/haystack_spec"
require "./regex_bench/haystack_generator"
require "./regex_bench/haystack_builder"
require "./regex_bench/benchmark_case"
require "./regex_bench/corpus"
require "./regex_bench/engine"
require "./regex_bench/workload"
require "./regex_bench/statistics"
require "./regex_bench/case_result"
require "./regex_bench/measure_a_case"
require "./regex_bench/runner_program"
require "./regex_bench/run_record"
require "./regex_bench/run_one_runner_process"
require "./regex_bench/run_cases_against_engines"
require "./regex_bench/report_document"
require "./regex_bench/build_the_report"
require "./regex_bench/render_the_markdown"
require "./regex_bench/write_the_report"
