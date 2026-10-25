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
