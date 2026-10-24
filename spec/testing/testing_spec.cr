require "../spec_helper"

describe Mica::Testing::Complexity do
  it_satisfies "MICA-TESTING-COMPLEXITY", "accepts linear growth and flags quadratic growth" do
    linear = Mica::Testing::Complexity.measure("linear", 1_000) { |size| size.to_i64 * 3 + 50 }
    linear.linear?.should be_true
    quadratic = Mica::Testing::Complexity.measure("quadratic", 1_000) { |size| size.to_i64 * size }
    quadratic.linear?.should be_false
    quadratic.ratio.should eq(16.0)
    quadratic.to_s.should contain("ratio 16.0")
    Mica::Testing::Complexity::Result.new("empty", 1, 4, 0_i64, 5_i64, 1.25).linear?.should be_false
  end
end

describe Mica::Testing::ByteMutator do
  mutator = Mica::Testing::ByteMutator.new(["<a b='1'>text</a>".to_slice], ["<", "&amp;"].map(&.to_slice))

  it_satisfies "MICA-TESTING-FUZZ", "produces the same case for the same seed and iteration" do
    (0...500).each do |iteration|
      mutator.case_bytes(9_i64, iteration).should eq(mutator.case_bytes(9_i64, iteration))
    end
    distinct = (0...500).map { |iteration| mutator.case_bytes(9_i64, iteration) }.uniq!.size
    distinct.should be > 300
  end

  it_satisfies "MICA-TESTING-FUZZ", "covers every hostile class and re-encodes inputs" do
    Mica::Testing::ByteMutator::HOSTILE.keys.size.should eq(16)
    mutator.utf16("\u{1F600}".to_slice, big_endian: true, with_mark: false).should eq(Bytes[0xD8, 0x3D, 0xDE, 0x00])
    mutator.utf32("A".to_slice, big_endian: false, with_mark: true).should eq(Bytes[0xFF, 0xFE, 0, 0, 0x41, 0, 0, 0])
    mutator.latin1("é€".to_slice).should eq(Bytes[0xE9, '?'.ord.to_u8])
    mutator.insert(Bytes[1, 2], 1, Bytes[9]).should eq(Bytes[1, 9, 2])
    mutator.remove(Bytes[1, 2, 3], 1, 5).should eq(Bytes[1])
    expect_raises(ArgumentError) { Mica::Testing::ByteMutator.new([] of Bytes) }
  end
end

describe Mica::Testing::FuzzCampaign do
  mutator = Mica::Testing::ByteMutator.new(["<a/>".to_slice])

  it_satisfies "MICA-TESTING-FUZZ", "counts non-Mica exceptions as crashes and Mica errors as rejections" do
    campaign = Mica::Testing::FuzzCampaign.new(mutator, seed: 1_i64, overrun_slack: 0_i64)
    report = campaign.run(20) do |_, iteration|
      meter = Mica::Core::WorkMeter.new
      raise IndexError.new("boom") if iteration == 3
      if iteration.even?
        Mica::Testing::FuzzCampaign::Trial.new("ok", nil, meter)
      else
        error = Mica::ParseError.new("bad", Mica::Core::Position.new(0_i64))
        Mica::Testing::FuzzCampaign::Trial.new(error.message.to_s, error, meter)
      end
    end
    report.cases.should eq(20)
    report.list_of_crashes.size.should eq(1)
    report.list_of_crashes.first.should start_with("1:3 IndexError")
    report.accepted.should eq(10)
    report.rejected.should eq(9)
    report.clean?.should be_false
  end

  it_satisfies "MICA-TESTING-FUZZ", "flags budget overruns and nondeterministic outcomes" do
    calls = 0
    campaign = Mica::Testing::FuzzCampaign.new(mutator, seed: 2_i64, overrun_slack: 10_i64, check_determinism: true)
    report = campaign.run(4) do |_, iteration|
      calls += 1
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 100))
      meter.charge(iteration == 1 ? 1_000 : 5)
      Mica::Testing::FuzzCampaign::Trial.new(iteration == 2 ? "run #{calls}" : "ok", nil, meter)
    end
    report.list_of_budget_overruns.size.should eq(1)
    report.list_of_budget_overruns.first.should start_with("2:1 ")
    report.list_of_nondeterministic_cases.size.should eq(1)
    report.to_s.should contain("budget_overruns=1")
  end
end

describe Mica::Testing::Traceability do
  catalog_text = "# comment\nX-1\t1.1\tFirst\nX-2\t1.2\tSecond\n\nX-3\t2\tThird\n"

  it_satisfies "MICA-TESTING-TRACEABILITY", "reports covered, uncovered and unknown requirement ids" do
    catalog = Mica::Testing::Traceability::Catalog.parse(catalog_text)
    catalog.list_of_requirements.size.should eq(3)
    registry = Mica::Testing::Traceability::Registry.new
    registry.record("X-1", "spec/a_spec.cr:3")
    registry.record("X-1", "spec/b_spec.cr:9")
    registry.record("X-9", "spec/c_spec.cr:1")
    coverage = registry.coverage(catalog)
    coverage.covered.keys.should eq(["X-1"])
    coverage.list_of_uncovered_ids.should eq(["X-2", "X-3"])
    coverage.unknown.keys.should eq(["X-9"])
    coverage.ratio.should be_close(1 / 3, 0.001)
    report = String.build { |io| registry.write_report(io, catalog) }
    report.should contain("X-1\t1.1\tcovered\tspec/a_spec.cr:3 spec/b_spec.cr:9")
    report.should contain("X-2\t1.2\tuncovered\t")
    report.should contain("X-9\t\tunknown\tspec/c_spec.cr:1")
  end

  it_satisfies "MICA-TESTING-TRACEABILITY", "rejects malformed lines and duplicate ids" do
    expect_raises(ArgumentError, /Malformed/) { Mica::Testing::Traceability::Catalog.parse("X-1 no tabs\n") }
    expect_raises(ArgumentError, /Duplicate/) { Mica::Testing::Traceability::Catalog.parse("X-1\t1\ta\nX-1\t1\tb\n") }
  end
end
