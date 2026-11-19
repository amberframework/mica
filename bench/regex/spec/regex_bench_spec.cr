require "./spec_helper"

private def run_record : RegexBench::RunRecord
  RegexBench::RunRecord.new(started_at: "2026-11-18T00:00:00Z", operating_system: "test", cpu: "test",
    logical_cpu_count: 1, memory_bytes: 0_i64, crystal_version: "test", harness_commit: "h", mica_ref: "m",
    mica_commit: "c", rebar_commit: "r", rebar_tarball_sha256: "s", list_of_corpora: ["rebar"],
    max_samples: 3, min_samples: 1, phase_seconds: 0.1, case_timeout_seconds: 1.0, redos_timeout_seconds: 1.0,
    engines: [] of RegexBench::EngineDescription)
end

private def family(name : String) : RegexBench::Corpus::RedosFamily
  RegexBench::Corpus::RedosFamily.from_json(%({"name": "#{name}", "pattern": "(a+)+$", "unit": "a", "source": "spec"}))
end

describe RegexBench::Statistics do
  describe ".of" do
    it "reports the median and the interpolated quartiles" do
      statistics = RegexBench::Statistics.of([4.0, 1.0, 3.0, 2.0, 5.0])
      statistics.median.should eq(3.0)
      statistics.p25.should eq(2.0)
      statistics.p75.should eq(4.0)
      statistics.relative_spread.should be_close(2.0 / 3.0, 1e-12)
    end

    it "is empty with no samples" do
      RegexBench::Statistics.of([] of Float64).has_samples?.should be_false
    end
  end

  describe ".geometric_mean" do
    it "multiplies out to the n-th root" do
      RegexBench::Statistics.geometric_mean([0.5, 2.0, 4.0]).should be_close(4.0 ** (1.0 / 3.0), 1e-12)
    end
  end

  describe ".log_log_slope" do
    it "is 1 for linear growth and 2 for quadratic growth" do
      linear = [1024.0, 2048.0, 4096.0].map { |n| {n, n * 3e-9} }
      quadratic = [1024.0, 2048.0, 4096.0].map { |n| {n, n * n * 1e-12} }
      RegexBench::Statistics.log_log_slope(linear).should be_close(1.0, 1e-9)
      RegexBench::Statistics.log_log_slope(quadratic).should be_close(2.0, 1e-9)
    end
  end
end

describe RegexBench::Workload do
  describe "#run" do
    it "counts non-overlapping matches" do
      RegexBench::Workload.new(literal_pattern("aa"), "aaaaa", "count").run.should eq(2)
    end

    it "sums match lengths for count-spans" do
      RegexBench::Workload.new(literal_pattern("ab"), "ab ab ab", "count-spans").run.should eq(6)
    end

    it "steps one character past an empty match, as String#scan does" do
      RegexBench::Workload.new(literal_pattern(""), "añb", "count").run.should eq(4)
    end

    it "counts lines with a match for grep, ignoring line terminators" do
      RegexBench::Workload.new(literal_pattern("x"), "x1\r\nno\nxx\n", "grep").run.should eq(2)
    end

    it "sums groups over every match on every line for grep-captures" do
      RegexBench::Workload.new(literal_pattern("x"), "xx\nx\n", "grep-captures").run.should eq(6)
    end

    it "reports one search for first-match" do
      RegexBench::Workload.new(literal_pattern("b"), "aaab", "first-match").run.should eq(1)
      RegexBench::Workload.new(literal_pattern("c"), "aaab", "first-match").run.should eq(0)
    end

    it "rejects a model it does not implement" do
      expect_raises(RegexBench::UnsupportedCaseError) do
        RegexBench::Workload.new(literal_pattern("a"), "a", "regex-redux")
      end
    end
  end
end

describe RegexBench::HaystackBuilder do
  describe "#build" do
    it "applies trim, repeat, prepend and append in rebar's order" do
      spec = RegexBench::HaystackSpec.new(contents: " ab ", trim: true, repeat: 3_i64, prepend: "<", append: ">")
      RegexBench::HaystackBuilder.new(spec, "").build.should eq("<ababab>")
    end

    it "keeps the lines in [line_start, line_end)" do
      spec = RegexBench::HaystackSpec.new(contents: "l0\nl1\nl2\nl3\n", line_start: 1_i64, line_end: 3_i64)
      RegexBench::HaystackBuilder.new(spec, "").build.should eq("l1\nl2\n")
    end
  end
end

describe RegexBench::HaystackGenerator do
  describe "#generate" do
    it "is deterministic and stays within the target size" do
      RegexBench::HaystackGenerator::LIST_OF_GENERATORS.each do |generator_name|
        first = RegexBench::HaystackGenerator.new(generator_name, 65_536_i64).generate
        second = RegexBench::HaystackGenerator.new(generator_name, 65_536_i64).generate
        first.should eq(second)
        first.bytesize.should be <= 65_536
        first.bytesize.should be > 60_000
        first.valid_encoding?.should be_true
      end
    end

    it "rejects an unknown generator" do
      expect_raises(RegexBench::CorpusError) { RegexBench::HaystackGenerator.new("nope", 1_i64) }
    end
  end
end

describe RegexBench::Corpus do
  corpus = RegexBench::Corpus.new(File.expand_path("../corpus", __DIR__), File.expand_path("../../data/regex", __DIR__))

  describe "#amber_cases" do
    it "expands every pattern at every size" do
      cases = corpus.amber_cases
      cases.size.should eq(26 * 4)
      cases.map(&.id).uniq.size.should eq(cases.size)
      cases.first.id.should end_with("@1KiB")
    end
  end

  describe "#redos_cases" do
    it "builds prepend + unit * n + append under the deadline" do
      redos_case = corpus.redos_cases.find! { |candidate| candidate.id == "redos/nested-plus-dollar@n=16" }
      RegexBench::HaystackBuilder.new(redos_case.haystack, "").build.should eq("a" * 16 + "b")
      redos_case.deadline_ms.should eq(1000)
      redos_case.model.should eq("first-match")
    end
  end

  describe "#rebar_cases" do
    it "loads the converted rebar definitions" do
      pending! "run /usr/bin/ruby bench/regex/scripts/rebar_corpus.rb first" unless File.exists?(File.join(corpus.rebar_directory, "rebar.json"))
      cases = corpus.rebar_cases
      cases.size.should be > 200
      cases.all?(&.has_expected_count?).should be_true
    end
  end
end

describe RegexBench::BuildTheReport do
  describe "#perform" do
    it "compares each engine with the baseline and lists the slower cases" do
      results = [
        case_result("a", "pcre2-jit", "ok", warm: 1.0),
        case_result("a", "mica", "ok", warm: 2.0),
        case_result("b", "pcre2-jit", "ok", warm: 1.0),
        case_result("b", "mica", "ok", warm: 0.5),
        case_result("c", "pcre2-jit", "ok", warm: 1.0, count: 3),
        case_result("c", "mica", "ok", warm: 1.0, count: 4),
      ]
      document = RegexBench::BuildTheReport.new(run_record, results, [] of RegexBench::Corpus::RedosFamily).perform
      overall = document.group_summaries.find! { |summary| summary.group == "all cases" }
      overall.eligible_count.should eq(2)
      overall.primary_geometric_mean.should be_close(1.0, 1e-12)
      document.slower_than_baseline.map(&.case_id).should eq(["a"])
      document.case_comparisons.find!(&.case_id.==("c")).detail.should contain("count mismatch")
    end

    it "passes a Mica family that stays linear and reports PCRE2 as the contrast" do
      results = [] of RegexBench::CaseResult
      [1024_i64, 4096_i64, 16384_i64].each do |n|
        results << case_result("r@#{n}", "pcre2-jit", n == 16384 ? "timeout" : "ok", warm: n * 1e-5, corpus: "redos",
          group: "redos", family: "f", size_units: n, deadline_ms: 1000)
        results << case_result("r@#{n}", "mica", "ok", warm: n * 1e-8, corpus: "redos", group: "redos", family: "f",
          size_units: n, deadline_ms: 1000)
      end
      document = RegexBench::BuildTheReport.new(run_record, results, [family("f")]).perform
      verdicts = document.deadline_verdicts.to_h { |verdict| {verdict.engine, verdict} }
      verdicts["mica"].verdict.should eq("pass")
      verdicts["mica"].growth_slope.should be_close(1.0, 1e-9)
      verdicts["pcre2-jit"].within_deadline?.should be_false
      verdicts["pcre2-jit"].verdict.should eq("contrast, no deadline: 2 ok, 1 timeout")
    end
  end
end

# A result whose warm search took *seconds* per iteration, timed in
# batches of *iterations_per_sample*.
private def batched_result(case_id : String, engine : String, seconds : Float64,
                           iterations_per_sample : Int32) : RegexBench::CaseResult
  benchmark_case = RegexBench::BenchmarkCase.new(
    id: case_id, corpus: "rebar", group: "rebar/test", subgroup: "rebar/test", model: "count",
    pattern: "x", case_insensitive: false, haystack: RegexBench::HaystackSpec.new(contents: "x"))
  RegexBench::CaseResult.new(benchmark_case: benchmark_case, engine: engine, status: "ok", count: 1,
    warm_search: RegexBench::Statistics.of([seconds, seconds, seconds], iterations_per_sample),
    compile: RegexBench::Statistics.of([1e-6]), cold_first_search: RegexBench::Statistics.of([2e-6]))
end

describe RegexBench::RenderTheMarkdown do
  describe "#perform" do
    it "lists each slower case's batch sizes beside its margin" do
      results = [batched_result("t", "pcre2-jit", 80e-9, 128), batched_result("t", "mica", 120e-9, 64)]
      document = RegexBench::BuildTheReport.new(run_record, results, [] of RegexBench::Corpus::RedosFamily).perform
      comparison = document.case_comparisons.find!(&.case_id.==("t"))
      comparison.engine_iterations_per_sample.should eq(64)
      comparison.baseline_iterations_per_sample.should eq(128)
      comparison.primary_ratio.should be_close(1.5, 1e-9)
      markdown = RegexBench::RenderTheMarkdown.new(document, results, "spec").perform
      markdown.should contain("| Batch (Mica / PCRE2-JIT) |")
      markdown.should contain("| t | count | 120.0 ns | 80.0 ns | 1.5x | +50.0% | 64 / 128 |")
      markdown.should contain("timed in calibrated batches")
    end
  end
end
