require "./spec_helper"

private class LiteralEngine < RegexBench::Engine
  def name : String
    "literal"
  end

  def version : String
    "spec"
  end

  def compile(pattern : String, case_insensitive : Bool, policy : RegexBench::SearchPolicy) : RegexBench::CompiledPattern
    literal_pattern(pattern)
  end
end

private def benchmark_case(id : String, *, corpus : String = "rebar", family : String = "",
                           size_units : Int64 = 0_i64) : RegexBench::BenchmarkCase
  RegexBench::BenchmarkCase.new(id: id, corpus: corpus, group: "#{corpus}/spec", subgroup: "#{corpus}/spec",
    model: corpus == "redos" ? "first-match" : "count", pattern: "b", case_insensitive: false,
    haystack: RegexBench::HaystackSpec.new(contents: "aaaab"), family: family, size_units: size_units)
end

private def list_of_spec_cases : Array(RegexBench::BenchmarkCase)
  list = (1..20).map { |index| benchmark_case("rebar/case-#{index}") }
  {16_i64, 256_i64, 4096_i64, 65_536_i64}.each do |size|
    list << benchmark_case("redos/nested@n=#{size}", corpus: "redos", family: "nested", size_units: size)
  end
  list
end

private def run_the_program(list_of_arguments : Array(String), input : String = "") : String
  output = IO::Memory.new
  RegexBench::RunnerProgram.new(LiteralEngine.new, list_of_arguments, IO::Memory.new(input), output).run
  output.to_s
end

describe RegexBench::OrderCasesAtRandom do
  describe "#perform" do
    it "replays the same order from the same seed and a different order from another" do
      first = RegexBench::OrderCasesAtRandom.new(list_of_spec_cases, 42_u64).perform.map(&.id)
      again = RegexBench::OrderCasesAtRandom.new(list_of_spec_cases, 42_u64).perform.map(&.id)
      other = RegexBench::OrderCasesAtRandom.new(list_of_spec_cases, 43_u64).perform.map(&.id)
      again.should eq(first)
      other.should_not eq(first)
      first.sort.should eq(list_of_spec_cases.map(&.id).sort)
      first.should_not eq(list_of_spec_cases.map(&.id))
    end

    it "keeps each ReDoS family's sizes ascending, so a timeout still skips the larger sizes" do
      (1_u64..50_u64).each do |seed|
        ordered = RegexBench::OrderCasesAtRandom.new(list_of_spec_cases, seed).perform
        sizes = ordered.select(&.belongs_to_the_redos_set?).map(&.size_units)
        sizes.should eq(sizes.sort)
      end
    end
  end
end

describe RegexBench::Statistics do
  describe ".paired_ratio_interval" do
    it "contains 1 for pairs of equal spread and excludes it for a tenfold shift" do
      same = [10.0, 11.0, 9.0, 10.5, 9.5, 10.2, 9.8, 10.1, 9.9, 10.3]
      shifted = same.map { |seconds| seconds * 10 }
      RegexBench::Statistics.paired_ratio_interval(same.reverse, same).includes?(1.0).should be_true
      interval = RegexBench::Statistics.paired_ratio_interval(shifted, same)
      interval.ratio.should be_close(10.0, 1e-9)
      interval.includes?(1.0).should be_false
      interval.low.should be <= interval.ratio
      interval.high.should be >= interval.ratio
    end

    it "rejects unpaired samples" do
      expect_raises(ArgumentError) { RegexBench::Statistics.paired_ratio_interval([1.0], [1.0, 2.0]) }
    end
  end
end

describe RegexBench::RunnerProgram do
  describe "#run" do
    it "pages the runner in with --page-in and does no regex work" do
      summary = RegexBench::PageInSummary.from_json(run_the_program(["--page-in"]))
      summary.image_count.should be > 0
      summary.page_count.should be > 0
    end

    it "times only the first compile and search with --process-cold" do
      sample = RegexBench::ProcessColdSample.from_json(run_the_program(["--process-cold"], benchmark_case("rebar/one").to_json))
      sample.succeeded?.should be_true
      sample.seconds.should be > 0
    end
  end
end

describe RegexBench::CaseResult do
  describe "#process_cold_seconds" do
    it "is the median of the fresh-process samples, or the in-process sample of an older run" do
      older = case_result("c", "mica", "ok", warm: 1.0, process_first: 0.5)
      older.process_cold_seconds.should eq(0.5)
      sampled = older.with_process_cold([0.3, 0.1, 0.2])
      sampled.process_cold_seconds.should eq(0.2)
      sampled.list_of_process_cold_seconds.should eq([0.3, 0.1, 0.2])
      RegexBench::CaseResult.from_json(sampled.to_json).process_cold.median.should eq(0.2)
    end
  end
end
