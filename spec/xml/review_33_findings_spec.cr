require "../spec_helper"

private def unlimited_meter : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
end

# Regression specs for the thirty-third Codex code review of 2026-10-24.
# Each threshold sits between the count measured before the fix and the
# count after it, so a lost charge fails the example.
describe "Codex review 33 findings" do
  it "1: charges the n log n canonical ordering of a long combining run" do
    options = Mica::XML::ParserOptions.new(check_normalization: true)
    meter = unlimited_meter
    Mica::XML.parse("<?xml version='1.1'?><r>x#{"́" * 5_000}</r>", options, meter: meter)
    meter.operations.should be >= 500_000
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 16, base_operations: 0)
    expect_raises(Mica::WorkBudgetExceededError) do
      Mica::XML.parse("<?xml version='1.1'?><r>x#{"́" * 50_000}</r>", options, meter: Mica::Core::WorkMeter.new(budget))
    end
  end

  it "2: charges the reference passes of attribute entity replacement text" do
    references = "&#38;#65;" * 5_000
    meter = unlimited_meter
    Mica::XML.parse("<!DOCTYPE r [<!ENTITY e '#{references}'>]><r a='&e;'/>", meter: meter)
    meter.operations.should be >= 200_000
  end

  it "7: charges the deduplication pass of a union" do
    document = Mica::XML.parse("<r>#{"<e/>" * 5_000}</r>")
    meter = unlimited_meter
    document.xpath_nodes("//e | //e", meter: meter).size.should eq(5_000)
    meter.operations.should be >= 500_000
  end
end
