require "../spec_helper"

private UNAWARE = Mica::XML::ParserOptions.new(namespace_aware: false)

# Regression specs for the sixteenth Codex code review of 2026-10-24.
describe "Codex review 16 findings" do
  it "1: finds the following start of many attributes of one deep element once" do
    depth = 500
    attributes = (1..2_000).join(" ") { |number| "a#{number}='1'" }
    xml = "#{"<d>" * depth}<leaf #{attributes}/>#{"</d>" * depth}"
    document = Mica::XML.parse(xml)
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    document.xpath_nodes("//@*/following::*", meter: meter).size.should eq(0)
    # The climb is charged, and done once for all 2,000 attributes.
    meter.operations.should be >= depth
    meter.operations.should be < 200_000
  end

  it "2: returns an empty node set for following and preceding from no contexts" do
    document = Mica::XML.parse("<r/>")
    document.xpath_nodes("/r/missing/following::*").size.should eq(0)
    document.xpath_nodes("/r/missing/preceding::*").size.should eq(0)
  end

  it "3: applies max_input_bytes to in-memory input and the first stream bytes" do
    options = Mica::XML::ParserOptions.new(max_input_bytes: 3_i64)
    expect_raises(Mica::LimitExceededError) { Mica::XML.parse("<r/>", options) }
    expect_raises(Mica::LimitExceededError) { Mica::XML.parse(IO::Memory.new("<r/>"), options) }
    Mica::XML.parse("<r/>", Mica::XML::ParserOptions.new(max_input_bytes: 4_i64))
  end

  it "4: charges the markup that read_inner_xml and read_outer_xml write" do
    text = "&amp;" * 10_000
    reader = Mica::XML::Reader.new("<r><e>#{text}</e></r>")
    reader.read
    reader.read
    before = reader.operations
    reader.read_outer_xml.bytesize.should be > 50_000
    (reader.operations - before).should be >= 50_000 + 10_000
  end

  it "5: keeps a name whole without namespace processing" do
    root = root_of(Mica::XML.parse("<p:r p:a='1'/>", UNAWARE))
    root.name.should eq("p:r")
    root.prefix.should be_nil
    root.attributes.first.name.should eq("p:a")
    reader = Mica::XML::Reader.new("<p:r/>", UNAWARE)
    reader.read
    reader.local_name.should eq("p:r")
    reader.prefix.should be_nil
  end

  it "6: records the parse operations of an expanded document" do
    reader = Mica::XML::Reader.new("<r><e><f/></e></r>")
    reader.read
    reader.read
    reader.expand.document.parse_operations.should be > 0
  end
end
