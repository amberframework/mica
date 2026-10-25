require "../spec_helper"

# Regression specs for the twenty-fifth Codex code review of 2026-10-24.
describe "Codex review 25 findings" do
  it "1: charges a wide start tag's namespace pass before it runs" do
    attributes = (1..5_000).join(" ") { |number| "p:a#{number}='1'" }
    xml = "<r xmlns:p='urn:p' #{attributes}/>"
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse(xml, meter: meter)
    meter.operations.should be >= 2 * xml.bytesize
  end

  it "2: charges converting a node value compared with a number" do
    value = "1" * 100_000
    document = Mica::XML.parse("<r a='#{value}'/>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_bool("//@a < 1", meter: meter).should be_false
    meter.operations.should be >= 3 * value.bytesize
  end

  it "3: completes an edit whose name-table work settles past the budget" do
    document = Mica::XML.parse("<r><?t x?></r>")
    pi = node_at(document, "/r/processing-instruction()")
    document.edit_budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 40, max_operations: 40)
    pi.name = "u"
    pi.name.should eq("u")
  end

  it "4: charges comparing long equal values for !=" do
    value = "v" * 100_000
    document = Mica::XML.parse("<r a='#{value}' b='#{value}'/>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_bool("//@a != //@b", meter: meter).should be_false
    meter.operations.should be >= 4 * value.bytesize
  end
end
