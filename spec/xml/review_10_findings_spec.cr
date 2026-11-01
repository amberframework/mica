require "../spec_helper"

private CHECKED_11 = Mica::XML::ParserOptions.new(check_normalization: true)

# Regression specs for the tenth Codex code review of 2026-10-24.
describe "Codex review 10 findings" do
  it "1: keeps lookups in an expanded document and in XPath off the reader's meter" do
    reader = Mica::XML::Reader.new("<r><e a='1'/>#{"<f/>" * 10}</r>")
    reader.read
    reader.read
    element = reader.expand
    name = "missing#{"m" * 1_000}"
    10_000.times { element[name]?.should be_nil }
    element.document.xpath_nodes("//#{name}").size.should eq(0)
    before = reader.operations
    reader.read.should be_true
    (reader.operations - before).should be < 1_000
  end

  it "2: points a rewritten attribute value's error at the offending source character" do
    {
      "<?xml version='1.1'?><r a='x&amp;e\u0301'/>"                                               => 34,
      "<?xml version='1.1'?><r a='x\r\n\te\u0301'/>"                                              => 32,
      "<?xml version='1.1'?><r a='&#x65;&#x301;'/>"                                               => 33,
      "<?xml version='1.1'?><!DOCTYPE r [<!ENTITY e 'ab'>]><r a='&e;  &e;e\u0301'/>"              => 67,
      "<?xml version='1.1'?><!DOCTYPE r [<!ATTLIST r a NMTOKENS #IMPLIED>]><r a='  x  e\u0301'/>" => 80,
    }.each do |xml, offset|
      error = expect_raises(Mica::XML::NormalizationError) { Mica::XML.parse(xml, CHECKED_11) }
      error.byte_offset.should eq(offset)
    end
  end

  it "3: rejects an XPath expression that is not valid UTF-8" do
    source = String.new(Bytes['/'.ord.to_u8, '/'.ord.to_u8, 'e'.ord.to_u8, '['.ord.to_u8, '\''.ord.to_u8, 0xFF_u8, '\''.ord.to_u8, ']'.ord.to_u8])
    expect_raises(Mica::XML::XPathError, /Invalid UTF-8 byte 0xFF at byte 5/) { Mica::XML::XPath.compile(source) }
  end

  it "4: charges substring-after() for the suffix it copies, not the needle" do
    document = Mica::XML.parse("<r/>")
    text = "a" * 100_000
    after = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_string("substring-after('#{text}', '#{text}')", meter: after).should eq("")
    search = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_bool("contains('#{text}', '#{text}')", meter: search).should be_true
    (after.operations - search.operations).abs.should be < 1_000
  end
end
