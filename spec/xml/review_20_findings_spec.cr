require "../spec_helper"

# Records the size of each write.
private class WriteSizes < IO
  getter sizes = [] of Int32

  def read(slice : Bytes) : Int32
    raise IO::Error.new("write-only")
  end

  def write(slice : Bytes) : Nil
    @sizes << slice.size
  end
end

# Regression specs for the twentieth Codex code review of 2026-10-24.
describe "Codex review 20 findings" do
  it "1: writes escaped text in bounded chunks" do
    io = WriteSizes.new
    root_of(Mica::XML.parse("<r>#{"t" * 100_000}</r>")).to_xml(io, indent: 0)
    io.sizes.max.should be <= 4096
  end

  it "3: allows restating a namespace binding already in scope" do
    document = Mica::XML.parse("<r xmlns:p='urn:u'><p:c/></r>")
    child = node_at(document, "/r/*")
    child["xmlns:p"] = "urn:u"
    expect_raises(Mica::Error, /rename/) { child["xmlns:p"] = "urn:other" }
  end

  it "4: charges the markup scan of an internal entity's replacement text" do
    text = "t" * 100_000
    plain = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML.parse("<!DOCTYPE r [<!ENTITY e '#{text}'>]><r/>", meter: plain)
    plain.operations.should be >= 2 * text.bytesize
  end
end

# Regression specs for the twenty-first Codex code review of 2026-10-24.
describe "Codex review 21 findings" do
  it "1: writes CDATA in bounded chunks" do
    io = WriteSizes.new
    root_of(Mica::XML.parse("<r><![CDATA[#{"t" * 100_000}]]></r>")).to_xml(io, indent: 0)
    io.sizes.max.should be <= 4096
  end

  it "2: charges converting a long number literal before it runs" do
    digits = "1" * 100_000
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    Mica::XML::XPath.compile(digits, meter)
    meter.operations.should be >= 5 * digits.bytesize
  end
end
