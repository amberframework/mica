require "../spec_helper"

# Regression specs for the twenty-eighth Codex code review of 2026-10-24.
# Each threshold sits between the count measured before the fix and the
# count after it, so a lost charge fails the example.
describe "Codex review 28 findings" do
  it "1: charges each path step and predicate, also on an empty node set" do
    document = Mica::XML.parse("<r/>")
    steps = "/*" * 2_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("/missing#{steps}", meter: meter).should be_empty
    meter.operations.should be >= 14_000
    predicates = "[1]" * 2_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("(/missing)#{predicates}", meter: meter).should be_empty
    meter.operations.should be >= 30_000
  end

  it "2 and 4: charges the attribute tallies of a wide tag" do
    attributes = (1..2_000).join(' ') { |number| "a#{number}='1'" }
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<r #{attributes}/>", meter: meter)
    meter.operations.should be >= 101_000
  end

  it "3: charges growing the binding table to a late name id" do
    names = (1..5_000).join { |number| "<n#{number}/>" }
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<r>#{names}<p:x xmlns:p='urn:p'/></r>", meter: meter)
    meter.operations.should be >= 195_000
  end

  it "5 and 6: charges walking an expanded element's attributes" do
    attributes = (1..2_000).join(' ') { |number| "a#{number}='1'" }
    reader = Mica::XML::Reader.new("<r><e #{attributes}/></r>")
    reader.read
    reader.read
    before = reader.operations
    reader.expand.attributes.size.should eq(2_000)
    (reader.operations - before).should be >= 3 * 2_000
  end

  it "7: charges folding in-memory bytes before an encoding switch" do
    spaces = " " * 100_000
    operations = {"ISO-8859-1", "UTF-8"}.map do |encoding|
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
      Mica::XML.parse("<?xml version='1.0'#{spaces}encoding='#{encoding}'?><r>cafe</r>", meter: meter)
      meter.operations
    end
    (operations[0] - operations[1]).should be >= spaces.bytesize
  end

  it "8: charges each context of an axis that yields one node" do
    attributes = (1..2_000).join(' ') { |number| "a#{number}='1'" }
    document = Mica::XML.parse("<r #{attributes}/>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("//@*/parent::node()", meter: meter).size.should eq(1)
    meter.operations.should be >= 10_000
  end

  it "9: charges looking up a long function or axis name" do
    name = "f" * 100_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expect_raises(Mica::XML::XPathError) { Mica::XML::XPath.compile("#{name}()", meter: meter) }
    meter.operations.should be >= 3 * name.bytesize
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    expect_raises(Mica::XML::XPathError) { Mica::XML::XPath.compile("#{name}::x", meter: meter) }
    meter.operations.should be >= 3 * name.bytesize
  end

  it "10: charges the output of substring, normalize-space and translate" do
    document = Mica::XML.parse("<r/>")
    text = "a" * 10_000
    {"string-length(substring('#{text}', 1))",
     "string-length(normalize-space('#{text}'))",
    }.each do |expression|
      meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
      document.xpath_float(expression, meter: meter).should eq(10_000.0)
      meter.operations.should be >= 5 * text.bytesize
    end
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_float("string-length(translate('#{text}', 'a', '\u{1F600}'))", meter: meter).should eq(10_000.0)
    meter.operations.should be >= 11 * text.bytesize
  end

  it "11: charges hashing a long notation name twice" do
    name = "n" * 40_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<!DOCTYPE r [<!NOTATION #{name} SYSTEM 'x'>]><r/>", meter: meter)
    meter.operations.should be >= 6 * name.bytesize
  end
end
