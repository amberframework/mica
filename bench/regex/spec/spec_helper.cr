require "spec"
require "../src/regex_bench"

# A literal-substring engine, so the harness specs need no regex engine.
private class LiteralCompiledPattern < RegexBench::CompiledPattern
  def initialize(@literal : String)
  end

  def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : RegexBench::Span?
    return if byte_offset > haystack.bytesize
    index = haystack.byte_index(@literal, byte_offset)
    return unless index
    RegexBench::Span.new(index, index + @literal.bytesize, count_groups ? 2 : 1)
  end
end

def literal_pattern(literal : String) : RegexBench::CompiledPattern
  LiteralCompiledPattern.new(literal)
end

def case_result(case_id : String, engine : String, status : String, *, warm : Float64 = 0.0, count : Int64 = 1,
                corpus : String = "rebar", group : String = "rebar/curated", family : String = "",
                size_units : Int64 = 0, limit_name : String = "", seconds_until_limit : Float64 = 0.0,
                deadline_ms : Int64 = 0, process_first : Float64 = 0.0) : RegexBench::CaseResult
  benchmark_case = RegexBench::BenchmarkCase.new(
    id: case_id, corpus: corpus, group: group, subgroup: group, model: corpus == "redos" ? "first-match" : "count",
    pattern: "x", case_insensitive: false, haystack: RegexBench::HaystackSpec.new(contents: "x"),
    family: family, size_units: size_units, deadline_ms: deadline_ms)
  RegexBench::CaseResult.new(benchmark_case: benchmark_case, engine: engine, status: status, count: count,
    limit_name: limit_name, seconds_until_limit: seconds_until_limit, process_first_search_seconds: process_first,
    warm_search: warm > 0 ? RegexBench::Statistics.of([warm]) : RegexBench::Statistics.new,
    compile: RegexBench::Statistics.of([0.001]), cold_first_search: RegexBench::Statistics.of([0.002]))
end

def run_record_for_specs : RegexBench::RunRecord
  RegexBench::RunRecord.new(started_at: "2026-11-18T00:00:00Z", operating_system: "test", cpu: "test",
    logical_cpu_count: 1, memory_bytes: 0_i64, crystal_version: "test", harness_commit: "h", mica_ref: "m",
    mica_commit: "c", rebar_commit: "r", rebar_tarball_sha256: "s", list_of_corpora: ["rebar"],
    max_samples: 3, min_samples: 1, phase_seconds: 0.1, case_timeout_seconds: 1.0, redos_timeout_seconds: 1.0,
    engines: [] of RegexBench::EngineDescription)
end
