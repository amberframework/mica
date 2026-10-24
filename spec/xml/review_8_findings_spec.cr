require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

# Regression specs for the eighth Codex code review of 2026-10-24.
describe "Codex review 8 findings" do
  it "1: keeps an expanded document's name-table work off the reader's meter" do
    reader = Mica::XML::Reader.new("<r><e/>#{"<f/>" * 10}</r>")
    reader.read
    reader.read
    element = reader.expand
    5_000.times { |number| element["name#{number}"] = "1" }
    before = reader.operations
    reader.read.should be_true
    (reader.operations - before).should be < 1_000
  end

  it "2: maps attribute name errors past XML 1.1 line ends" do
    {
      "<?xml version='1.1'?><r\u0085á='1'/>"    => 26,
      "<?xml version='1.1'?><r á='1'/>"         => 27,
      "<?xml version='1.1'?><r\r\u0085 á='1'/>" => 28,
    }.each do |xml, offset|
      error = expect_raises(Mica::XML::NormalizationError) { Mica::XML.parse(xml, CHECKED_11) }
      error.byte_offset.should eq(offset)
      error.position.line.should eq(2)
    end
  end

  it "3: charges copying a deleted value and counts stored values in the edit allowance" do
    value = "v" * 100_000
    document = Mica::XML.parse("<r a='#{value}'/>")
    meter = document.edit_meter
    meter.units.should be >= value.bytesize
    before = meter.operations
    root_of(document).delete("a").should eq(value)
    (meter.operations - before).should be >= value.bytesize
  end

  it "4: writes numbers and booleans as attribute values" do
    document = Mica::XML.parse("<r/>")
    root = root_of(document)
    root["n"] = 42
    root["f"] = 1.5
    root["b"] = true
    {root["n"], root["f"], root["b"]}.should eq({"42", "1.5", "true"})
  end
end
