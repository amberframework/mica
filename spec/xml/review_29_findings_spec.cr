require "../spec_helper"

private def unlimited_meter : Mica::Core::WorkMeter
  Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
end

private def expired_meter : Mica::Core::WorkMeter
  meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.new(timeout: 1.nanosecond))
  sleep 1.millisecond
  meter
end

private def utf16le(text : String) : Bytes
  bytes = IO::Memory.new
  bytes.write(Bytes[0xFF, 0xFE])
  text.each_char do |char|
    bytes.write_byte((char.ord & 0xFF).to_u8)
    bytes.write_byte((char.ord >> 8).to_u8)
  end
  bytes.to_slice
end

# Regression specs for the twenty-ninth Codex code review of 2026-10-24.
# Each threshold sits between the count measured before the fix and the
# count after it, so a lost charge fails the example.
describe "Codex review 29 findings" do
  it "1: stops a short compile, evaluation or edit on an expired meter" do
    expect_raises(Mica::DeadlineExceededError) { Mica::XML::XPath.compile("1", meter: expired_meter) }
    document = Mica::XML.parse("<r/>")
    expect_raises(Mica::DeadlineExceededError) { document.xpath_bool("true()", meter: expired_meter) }
    document.renew_edit_meter(Mica::Core::WorkBudget.new(timeout: 1.nanosecond))
    sleep 1.millisecond
    root = document.root || fail "no root"
    expect_raises(Mica::DeadlineExceededError) { root["a"] = "1" }
    root["a"]?.should be_nil
  end

  it "5: charges the scan and the collapsed copy of a tokenized value" do
    token = "t" * 100_000
    meter = unlimited_meter
    Mica::XML.parse("<!DOCTYPE r [<!ATTLIST r a NMTOKENS #IMPLIED>]><r a='#{token}'/>", meter: meter)
    meter.operations.should be >= 500_000
    meter = unlimited_meter
    Mica::XML.parse("<!DOCTYPE r [<!ATTLIST r a NMTOKENS '#{token}'>]><r/>", meter: meter)
    meter.operations.should be >= 580_000
  end

  it "8: charges the XML 1.1 normalization walk over every attribute" do
    attributes = (1..2_000).join(' ') { |number| "a#{number}=''" }
    meter = unlimited_meter
    options = Mica::XML::ParserOptions.new(check_normalization: true)
    Mica::XML.parse("<?xml version='1.1'?><r #{attributes}/>", options, meter: meter)
    meter.operations.should be >= 180_000
  end

  it "9: charges each parent link a descendant step climbs" do
    depth = 1_000
    document = Mica::XML.parse("<r>#{"<a>" * depth}<leaf/>#{"</a>" * depth}</r>")
    meter = unlimited_meter
    document.xpath_nodes("(//leaf)#{"/descendant-or-self::leaf" * 50}", meter: meter).size.should eq(1)
    meter.operations.should be >= 50 * depth
  end

  it "10: charges the DOCTYPE name's QName check" do
    name = "n" * 40_000
    meter = unlimited_meter
    Mica::XML.parse("<!DOCTYPE #{name}><#{name}/>", meter: meter)
    meter.operations.should be >= 6 * name.bytesize
  end

  it "16: checks a UTF-16 label's byte order without copying it" do
    Mica::XML.parse(utf16le("<?xml version='1.0' encoding='utf-16le'?><r/>")).root.try(&.name).should eq("r")
    expect_raises(Mica::EncodingError) do
      Mica::XML.parse(utf16le("<?xml version='1.0' encoding='UTF-16be'?><r/>"))
    end
  end

  it "17: charges both steps of an abbreviated descendant pair" do
    depth = 1_000
    document = Mica::XML.parse("<r>#{"<a>" * depth}<leaf/>#{"</a>" * depth}</r>")
    meter = unlimited_meter
    document.xpath_nodes("/r#{"//leaf" * 200}", meter: meter)
    meter.operations.should be >= 8_500
  end
end
