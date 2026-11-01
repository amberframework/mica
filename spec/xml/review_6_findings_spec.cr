require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

# Regression specs for the sixth Codex code review of 2026-10-24.
describe "Codex review 6 findings" do
  it "1: steps past renamed local-name candidates in linear time" do
    count = 5_000
    declarations = (1..count).join(" ") { |number| "xmlns:p#{number}='urn:p#{number}'" }
    attributes = (1..count).join(" ") { |number| "p#{number}:a='#{number}'" }
    document = Mica::XML.parse("<r #{declarations} #{attributes}/>")
    root = root_of(document)
    root["p1:a"] = "first"
    started = Time.instant
    root.attributes.to_a.each { |attribute| attribute.name = "#{attribute.qualified_name.split(':').first}:b" }
    count.times { root.delete("a").should be_nil }
    (Time.instant - started).should be < 2.seconds
  end

  it "2: charges comparing string literals for every context node" do
    document = Mica::XML.parse("<r>#{"<e/>" * 1_000}</r>")
    literal = "a" * 10_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("//e['#{literal}b' = '#{literal}c']", meter: meter).size.should eq(0)
    meter.operations.should be >= 1_000 * 10_000
  end

  it "3: treats a class-0 character after a non-starter as blocked" do
    error = expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse("<?xml version='1.1'?><a>q\u{113C2}\u{0301}\u{113B8}\u{0315}\u{0300}</a>", CHECKED_11)
    end
    error.byte_offset.should eq(37)
  end

  it "4: meters every edit call, including ones that find nothing" do
    document = Mica::XML.parse("<r/>")
    root = root_of(document)
    name = "z" * 10_000
    before = document.edit_meter.operations
    root.delete(name).should be_nil
    (document.edit_meter.operations - before).should be >= name.bytesize
    expect_raises(Mica::Error) { node_at(document, "/r").name = "" }
  end

  it "5: charges name-table rehashes that edits cause to the edit meter" do
    document = Mica::XML.parse("<r/>")
    root = root_of(document)
    prepaid = document.names.prepaid_operations
    meter = document.edit_meter
    before = meter.operations
    5_000.times { |number| root["n#{number}"] = "1" }
    rehashed = document.names.prepaid_operations - prepaid
    rehashed.should be > 0
    (meter.operations - before).should be >= rehashed
  end

  it "6: adds one unit per edit call plus the bytes it is given" do
    document = Mica::XML.parse("<r/>")
    root = root_of(document)
    units = document.edit_meter.units
    root["a"] = "bcd"
    (document.edit_meter.units - units).should eq(1 + 4)
  end

  it "7: starts a fresh edit meter when the edit budget changes" do
    document = Mica::XML.parse("<r/>")
    root = root_of(document)
    root["a"] = "1"
    document.edit_budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 0, max_operations: 0)
    expect_raises(Mica::WorkBudgetExceededError) { root["b"] = "2" }
  end
end
