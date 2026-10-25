require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)
private UNAWARE    = Mica::XML::ParserOptions.new(namespace_aware: false)

# Regression specs for the eleventh Codex code review of 2026-10-24.
describe "Codex review 11 findings" do
  it "1: keeps name splits that reading an expanded document makes off the reader's meter" do
    names = (1..2_000).join { |number| "<p#{number}:e#{number} p#{number}:a#{number}='1'/>" }
    reader = Mica::XML::Reader.new("<r><x>#{names}</x><f/></r>", UNAWARE)
    reader.read
    reader.read
    element = reader.expand
    element.children.each do |child|
      child.name.should start_with("e")
      child.prefix.should_not be_nil
      child.attributes.each(&.name)
    end
    before = reader.operations
    reader.read.should be_true
    (reader.operations - before).should be < 1_000
  end

  it "2: finds an attribute by a local name that was never interned" do
    document = Mica::XML.parse("<p:r p:a='1'/>", UNAWARE)
    root = root_of(document)
    root["a"]?.should eq("1")
    root["p:a"]?.should eq("1")
    root.delete("a").should eq("1")
    root["p:a"]?.should be_nil
  end

  it "3: charges replaying a rewritten value to the parse meter" do
    entities = "<!ENTITY e0 'ab'>" + (1..10).join { |level| "<!ENTITY e#{level} '&e#{level - 1};&e#{level - 1};'>" }
    xml = "<?xml version='1.1'?><!DOCTYPE r [#{entities}]><r a='&e10;é'/>"
    replayed = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expect_raises(Mica::XML::NormalizationError) { Mica::XML.parse(xml, CHECKED_11, meter: replayed) }
    plain = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse(xml.sub("&e10;e\u0301", "e\u0301&e10;"), CHECKED_11, meter: plain)
    end
    (replayed.operations - plain.operations).should be >= 2 * 1_024
  end
end

# Regression specs for the twelfth Codex code review of 2026-10-24.
describe "Codex review 12 findings" do
  it "1: reads an indexed attribute by local name without charging the edit meter" do
    document = Mica::XML.parse("<p:r p:a='1'/>", UNAWARE)
    root = root_of(document)
    root.delete("missing").should be_nil
    document.edit_budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 0, max_operations: 0)
    root["a"]?.should eq("1")
    root["p:a"]?.should eq("1")
  end
end

# Regression specs for the thirteenth Codex code review of 2026-10-24.
describe "Codex review 13 findings" do
  it "1: quotes at most a short excerpt of a long expression in XPath errors" do
    long = "a" * 1_000_000
    {":#{long}", "'é#{long}", "//e[#{long}", "#{long}!"}.each do |source|
      error = expect_raises(Mica::XML::XPathError) { Mica::XML::XPath.compile(source) }
      (error.message || "").bytesize.should be < 600
    end
    invalid = String.new(Bytes[0xFF_u8] + long.to_slice)
    error = expect_raises(Mica::XML::XPathError, /0xFF at byte 0/) { Mica::XML::XPath.compile(invalid) }
    (error.message || "").bytesize.should be < 600
  end
end
