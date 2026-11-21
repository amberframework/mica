require "./spec_helper"

# Records which String object every search was handed.
private class RecordingPattern < RegexBench::CompiledPattern
  def initialize(@list_of_searched : Array(UInt64))
  end

  def find(haystack : String, byte_offset : Int32, first_search : Bool, count_groups : Bool) : RegexBench::Span?
    @list_of_searched << haystack.object_id
    index = haystack.byte_index("b", byte_offset)
    RegexBench::Span.new(index, index + 1, 1) if index
  end
end

private class RecordingEngine < RegexBench::Engine
  getter list_of_searched = [] of UInt64

  def name : String
    "recording"
  end

  def version : String
    "spec"
  end

  def compile(pattern : String, case_insensitive : Bool, policy : RegexBench::SearchPolicy) : RegexBench::CompiledPattern
    RecordingPattern.new(@list_of_searched)
  end
end

private def first_match_case : RegexBench::BenchmarkCase
  RegexBench::BenchmarkCase.new(id: "spec/first-match", corpus: "rebar", group: "rebar/spec", subgroup: "rebar/spec",
    model: "first-match", pattern: "b", case_insensitive: false,
    haystack: RegexBench::HaystackSpec.new(contents: "aaaab"))
end

private def quick_settings : RegexBench::MeasurementSettings
  RegexBench::MeasurementSettings.new(max_samples: 3, min_samples: 1, phase_seconds: 0.001, warmup_seconds: 0.001)
end

describe RegexBench::MeasureACase do
  describe "#perform" do
    it "hands every timed search a String of its own, as each web request brings a new one" do
      engine = RecordingEngine.new
      result = RegexBench::MeasureACase.new(engine, first_match_case, quick_settings, "").perform
      result.status.should eq("ok")
      # The process-cold search and the verifying iteration come first and
      # search the haystack as built; every search after them is timed.
      timed = engine.list_of_searched[2..]
      timed.size.should be > 4
      timed.each_cons_pair do |previous, current|
        current.should_not eq(previous)
      end
    end

    it "times compile plus the first search as the first regex work of the process" do
      result = RegexBench::MeasureACase.new(RecordingEngine.new, first_match_case, quick_settings, "").perform
      result.process_first_search_seconds.should be > 0
    end
  end
end

describe RegexBench::HaystackCopies do
  describe "#prepare" do
    it "makes one equal, separate String per run of the batch" do
      copies = RegexBench::HaystackCopies.new("añb")
      copies.prepare(4)
      list_of_copies = (0...4).map { |index| copies[index] }
      list_of_copies.each(&.should(eq("añb")))
      list_of_copies.map(&.object_id).uniq.size.should eq(4)
      list_of_copies.none?(&.same?(copies.original)).should be_true
    end

    it "rotates through at least two copies when a batch of copies would pass the byte ceiling" do
      copies = RegexBench::HaystackCopies.new("abcd", byte_ceiling: 10_i64)
      copies.prepare(8)
      copies.copy_count.should eq(2)
      copies[0].same?(copies[1]).should be_false
      copies[2].same?(copies[0]).should be_true
    end
  end
end

describe RegexBench::TimeInCalibratedBatches do
  describe "#measure" do
    it "prepares each batch before its clock starts and hands every run its index in the batch" do
      now = 0.0
      clock = -> { now }
      list_of_prepared = [] of Int32
      list_of_indexes = [] of Int32
      prepare = ->(iterations : Int32) do
        list_of_prepared << iterations
        now += 1.0 # setup time the timing must leave out
        nil
      end
      statistics = RegexBench::TimeInCalibratedBatches.new(RegexBench::MeasurementSettings.new, clock)
        .measure(prepare) do |index|
          list_of_indexes << index
          now += 100e-9
        end
      statistics.median.should be_close(100e-9, 1e-15)
      list_of_prepared.should_not be_empty
      list_of_indexes.max.should eq(statistics.iterations_per_sample - 1)
    end
  end
end

describe RegexBench::BuildTheReport do
  describe "#perform" do
    it "reports the process-cold ratio and every metric's absolute geometric means beside warm, compile and cold" do
      results = [
        case_result("a", "pcre2-jit", "ok", warm: 1e-6, process_first: 40e-6),
        case_result("a", "mica", "ok", warm: 2e-6, process_first: 20e-6),
      ]
      document = RegexBench::BuildTheReport.new(run_record_for_specs, results, [] of RegexBench::Corpus::RedosFamily).perform
      comparison = document.case_comparisons.find!(&.case_id.==("a"))
      comparison.process_cold_ratio.should be_close(0.5, 1e-12)
      overall = document.group_summaries.find! { |summary| summary.group == "all cases" }
      overall.process_cold_geometric_mean.should be_close(0.5, 1e-12)
      overall.engine_seconds.process_cold.should be_close(20e-6, 1e-15)
      overall.baseline_seconds.process_cold.should be_close(40e-6, 1e-15)
      overall.engine_seconds.warm.should be_close(2e-6, 1e-15)
      markdown = RegexBench::RenderTheMarkdown.new(document, results, "spec").perform
      markdown.should contain("Process-cold")
      markdown.should contain("0.5x (20.0 µs / 40.0 µs)")
    end
  end
end
