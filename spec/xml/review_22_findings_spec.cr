require "../spec_helper"

# Regression specs for the twenty-second Codex code review of 2026-10-24.
describe "Codex review 22 findings" do
  it "1 and 2: charges XPath token copies before they happen" do
    long = "a" * 100_000
    {"#{"1" * 100_000}", "'#{long}'", "p:#{long}"}.each do |source|
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
      begin
        Mica::XML::XPath.compile(source, meter)
      rescue Mica::Error
      end
      meter.operations.should be >= 2 * 100_000
    end
  end

  it "3: charges copying the internal subset and declaration values" do
    subset = "<!-- #{"c" * 100_000} -->"
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<!DOCTYPE r [#{subset}]><r/>", meter: meter)
    meter.operations.should be >= 2 * subset.bytesize
  end

  it "4: charges compaction and growth of a streamed buffer" do
    text = "t" * 300_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse(IO::Memory.new("<r>#{text}</r>"), meter: meter)
    in_memory = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<r>#{text}</r>", meter: in_memory)
    (meter.operations - in_memory.operations).should be >= text.bytesize
  end

  it "5: undeclares a prefix in XML 1.1 edits and builders" do
    document = Mica::XML.parse("<?xml version='1.1'?><r xmlns:p='urn:p'><c/></r>")
    child = node_at(document, "/r/c")
    child["xmlns:p"] = ""
    expect_raises(Mica::Error, /not bound/) { child["p:a"] = "1" }
    expect_raises(Mica::Error, /empty URI/) do
      node_at(Mica::XML.parse("<r xmlns:p='urn:p'><c/></r>"), "/r/c")["xmlns:p"] = ""
    end
    xml = Mica::XML.build(version: "1.1") do |builder|
      builder.element("r", {"xmlns:p" => "urn:p"}) do
        builder.element("c", {"xmlns:p" => ""}) { }
      end
    end
    xml.should contain("xmlns:p=\"\"")
  end
end
