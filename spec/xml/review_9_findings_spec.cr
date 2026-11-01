require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

# Regression specs for the ninth Codex code review of 2026-10-24.
describe "Codex review 9 findings" do
  it "1: charges the suffix substring-after() copies" do
    document = Mica::XML.parse("<r>#{"<e/>" * 1_000}</r>")
    literal = "x#{"a" * 10_000}"
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_float("count(//e[substring-after('#{literal}', 'x') = 'z'])", meter: meter).should eq(0.0)
    meter.operations.should be >= 1_000 * 10_000
  end

  it "2: gives an expanded document its own name table on its first edit" do
    reader = Mica::XML::Reader.new("<r><e/><f/></r>")
    reader.read
    reader.read
    element = reader.expand
    shared = reader.names
    names_before = shared.size
    5_000.times { |number| element["fresh#{number}"] = "1" }
    shared.size.should eq(names_before)
    element.document.names.should_not be(shared)
    element["fresh1"].should eq("1")
    reader.read.should be_true
    reader.name.should eq("f")
  end

  it "3: points an attribute value's normalization error at the offending character" do
    error = expect_raises(Mica::XML::NormalizationError) do
      Mica::XML.parse("<?xml version='1.1'?><r a='é'/>", CHECKED_11)
    end
    error.byte_offset.should eq(28)
  end
end
