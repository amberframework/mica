require "../spec_helper"

# Regression specs for the thirty-fifth Codex code review of 2026-10-24.
describe "Codex review 35 findings" do
  it "1: leaves every child in place when replacing them trips the budget" do
    document = Mica::XML.parse("<r>#{"<e/>" * 2_000}</r>")
    root = document.root || fail "no root"
    replaced = false
    failures = 0
    base = 0
    until replaced || base > 100_000
      document.renew_edit_meter(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: base))
      begin
        root.content = "x"
        replaced = true
      rescue Mica::WorkBudgetExceededError
        failures += 1
        root.children.size.should eq(2_000)
      end
      base += 250
    end
    failures.should be > 0
    replaced.should be_true
    root.children.size.should eq(1)
  end

  it "2: counts an empty element toward max_element_depth" do
    options = Mica::XML::ParserOptions.new(max_element_depth: 1)
    expect_raises(Mica::LimitExceededError, /max_element_depth/) { Mica::XML.parse("<r><e/></r>", options) }
    Mica::XML.parse("<r/>", options).root.try(&.name).should eq("r")
  end

  it "3: checks the budget by bytes in literal scans of multibyte characters" do
    literal = "\u{1F600}" * 200_000
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 100_000)
    options = Mica::XML::ParserOptions.new(work_budget: budget)
    error = expect_raises(Mica::WorkBudgetExceededError) do
      Mica::XML.parse("<!DOCTYPE r SYSTEM '#{literal}'><r/>", options)
    end
    error.byte_offset.should be < 250_000
  end
end

# Regression spec for the thirty-sixth Codex code review of 2026-10-24.
describe "Codex review 36 findings" do
  it "1: checks the budget by bytes while skipping XML 1.1 line ends" do
    spaces = " " * 200_000
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 100_000)
    options = Mica::XML::ParserOptions.new(work_budget: budget)
    error = expect_raises(Mica::WorkBudgetExceededError) do
      Mica::XML.parse("<?xml version='1.1'?><r#{spaces}/>", options)
    end
    # Checked every 64 KiB, the 100,000-operation budget trips by the
    # second check; counting characters would first check after 192 KiB.
    error.byte_offset.should be < 160_000
  end
end

# Regression specs for the thirty-seventh Codex code review of 2026-10-24.
describe "Codex review 37 findings" do
  it "2 and 3: charges XPath lexing by bytes and positions a trip where it happened" do
    literal = "\u{1F600}" * 100_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML::XPath.compile("'#{literal}'", meter: meter)
    meter.operations.should be >= 4 * 100_000
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 50_000)
    error = expect_raises(Mica::WorkBudgetExceededError) do
      Mica::XML::XPath.compile("'#{literal}'", meter: Mica::Core::WorkMeter.new(budget))
    end
    error.byte_offset.should be > 40_000
  end

  it "1: charges a builder's subset check copy to the check's own meter" do
    subset = "<!-- #{"c" * 1_000} -->"
    Mica::XML.build(&.dtd("r", nil, nil, subset)).should contain(subset)
  end
end

# Regression spec for the thirty-ninth Codex code review of 2026-10-24.
describe "Codex review 39 findings" do
  it "1: reports KMP comparisons in blocks before they run, within the stated bound" do
    haystack = ("a" * 100_000).to_slice
    needle = ("a" * 5_000 + "b").to_slice
    reports = [] of Int32
    Mica::Core::ByteSearch.index(haystack, needle) { |count| reports << count }.should be_nil
    reports.max.should be <= Mica::Core::ByteSearch::STEP_CHUNK
    reports.sum.should be <= 2 * haystack.size + 3 * needle.size
    # Counting real comparisons beside the reports: every scan comparison
    # was reported before it ran. The all-`a` haystack and `a…ab` needle
    # make the scan fall back on almost every byte.
    reported = 0_i64
    Mica::Core::ByteSearch.index(haystack, needle) { |count| reported += count }
    reported.should be >= 2 * haystack.size - 2 * needle.size
  end

  it "2: credits a stream's sniffed bytes before charging their copy" do
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 64, base_operations: 0)
    options = Mica::XML::ParserOptions.new(work_budget: budget)
    Mica::XML.parse(IO::Memory.new("<r>#{"x" * 100}</r>"), options).root.try(&.name).should eq("r")
  end
end

# Regression spec for the forty-second Codex code review of 2026-10-25.
describe "Codex review 42 findings" do
  it "1: charges copying a positional step's selected nodes" do
    document = Mica::XML.parse("<r>#{"<p>#{"<e/>" * 20}</p>" * 500}</r>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("//p/e[position() > 0]", meter: meter).size.should eq(10_000)
    # Measured 81,597 before the copy was charged and 91,597 after.
    meter.operations.should be >= 90_000
  end
end

# Regression spec for the forty-third Codex code review of 2026-10-25.
describe "Codex review 43 findings" do
  it "2: checks overruns against an unlimited allowance without overflow" do
    mutator = Mica::Testing::ByteMutator.new(["<a/>".to_slice])
    campaign = Mica::Testing::FuzzCampaign.new(mutator, seed: 3_i64, overrun_slack: 70_000_i64)
    report = campaign.run(3) do |_, _|
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
      meter.charge(10)
      Mica::Testing::FuzzCampaign::Trial.new("ok", nil, meter)
    end
    report.cases.should eq(3)
    report.list_of_budget_overruns.should be_empty
  end
end

# Regression spec for the forty-fourth Codex code review of 2026-10-25.
describe "Codex review 44 findings" do
  it "1: rejects a negative operation cap" do
    expect_raises(ArgumentError, /max_operations/) { Mica::Core::WorkBudget.new(max_operations: -1) }
  end
end

# Regression specs for the forty-sixth Codex code review of 2026-10-25.
describe "Codex review 46 findings" do
  mutator = Mica::Testing::ByteMutator.new(["<a/>".to_slice])

  it "2: clips a trial's failure detail in the crash list" do
    campaign = Mica::Testing::FuzzCampaign.new(mutator, seed: 4_i64, overrun_slack: 0_i64)
    report = campaign.run(1) do |_, _|
      Mica::Testing::FuzzCampaign::Trial.new("ok", nil, Mica::Core::WorkMeter.new, ["x" * 10_000])
    end
    report.list_of_crashes.first.size.should be < 200
  end

  it "3: does not count a crashing replay as another case" do
    calls = 0
    campaign = Mica::Testing::FuzzCampaign.new(mutator, seed: 5_i64, overrun_slack: 0_i64, check_determinism: true)
    report = campaign.run(2) do |_, _|
      calls += 1
      raise IndexError.new("replay") if calls.even?
      Mica::Testing::FuzzCampaign::Trial.new("ok", nil, Mica::Core::WorkMeter.new)
    end
    report.cases.should eq(2)
    report.list_of_crashes.size.should eq(2)
    report.list_of_crashes.first.should contain("(replay)")
  end
end

# Regression spec for the forty-seventh Codex code review of 2026-10-25.
describe "Codex review 47 findings" do
  it "1: clips a long context in a budget message" do
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 0))
    meter.charge(1)
    error = expect_raises(Mica::WorkBudgetExceededError) do
      meter.enforce("x" * 1_000_000) { Mica::Core::Position.new(0_i64) }
    end
    (error.message || "").size.should be < 600
  end
end
