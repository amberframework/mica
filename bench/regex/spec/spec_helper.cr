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
                deadline_ms : Int64 = 0) : RegexBench::CaseResult
  benchmark_case = RegexBench::BenchmarkCase.new(
    id: case_id, corpus: corpus, group: group, subgroup: group, model: corpus == "redos" ? "first-match" : "count",
    pattern: "x", case_insensitive: false, haystack: RegexBench::HaystackSpec.new(contents: "x"),
    family: family, size_units: size_units, deadline_ms: deadline_ms)
  RegexBench::CaseResult.new(benchmark_case: benchmark_case, engine: engine, status: status, count: count,
    limit_name: limit_name, seconds_until_limit: seconds_until_limit,
    warm_search: warm > 0 ? RegexBench::Statistics.of([warm]) : RegexBench::Statistics.new,
    compile: RegexBench::Statistics.of([0.001]), cold_first_search: RegexBench::Statistics.of([0.002]))
end
