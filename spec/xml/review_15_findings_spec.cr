require "../spec_helper"

# Regression specs for the fifteenth Codex code review of 2026-10-24.
describe "Codex review 15 findings" do
  it "1: charges reader value copies and attribute lookups" do
    text = "t" * 10_000
    reader = Mica::XML::Reader.new("<r a='#{text}'>#{text}</r>")
    reader.read
    before = reader.operations
    10.times { reader["a"]?.should eq(text) }
    (reader.operations - before).should be >= 10 * text.bytesize
    reader.read
    before = reader.operations
    10.times { reader.value.should eq(text) }
    (reader.operations - before).should be >= 10 * text.bytesize
  end

  it "2: quotes excerpts of entity names, PI targets and unknown attribute types" do
    name = "n" * 40_000
    {
      "<!DOCTYPE r [<!ENTITY #{name} '<a>'>]><r>&#{name};</a></r>",
      "<r><?p:#{name} x?></r>",
      "<!DOCTYPE r [<!ATTLIST r a #{name} #IMPLIED>]><r/>",
    }.each do |xml|
      error = expect_raises(Mica::ParseError) { Mica::XML.parse(xml) }
      (error.message || "").bytesize.should be < 800
    end
  end

  it "3: quotes an excerpt of a variable holding nodes from another document" do
    other = Mica::XML.parse("<o/>")
    name = "v" * 100_000
    document = Mica::XML.parse("<r/>")
    variables = {name => other.xpath_nodes("/o").as(Mica::XML::XPath::Value)}
    error = expect_raises(Mica::XML::XPathError, /another document/) { document.xpath_nodes("$#{name}", variables: variables) }
    (error.message || "").bytesize.should be < 600
  end

  it "4: charges a union before joining and substring-before() before copying" do
    document = Mica::XML.parse("<r>#{"<e/>" * 1_000}</r>")
    meter = Mica::Core::WorkMeter.new(Mica::Core::WorkBudget.unlimited)
    text = "a" * 100_000
    document.xpath_string("substring-before('#{text}b', 'b')", meter: meter).should eq(text)
    meter.operations.should be >= 2 * text.bytesize
    document.xpath_nodes("//e | //e").size.should eq(1_000)
  end

  it "5: declares inherited namespaces on an expanded subtree" do
    reader = Mica::XML::Reader.new("<r xmlns:p='urn:p' xmlns='urn:d' xmlns:q='urn:q'><x><p:y p:a='1'><z/></p:y></x></r>")
    reader.read
    reader.read
    element = reader.expand
    xml = element.to_xml(indent: 0)
    xml.should contain("xmlns:p=\"urn:p\"")
    xml.should contain("xmlns=\"urn:d\"")
    xml.should_not contain("urn:q")
    reparsed = Mica::XML.parse(xml)
    reparsed.xpath_nodes("//*[local-name() = 'y']").size.should eq(1)
    element.document.xpath_nodes("//p:y", namespaces: {"p" => "urn:p"}).size.should eq(1)
  end

  it "6: quotes excerpts of a builder encoding and a missing attribute name" do
    long = "e" * 100_000
    error = expect_raises(Mica::XML::BuilderError) { Mica::XML.build(encoding: long) { |xml| xml.element("r") { } } }
    (error.message || "").bytesize.should be < 600
    root = root_of(Mica::XML.parse("<r/>"))
    error = expect_raises(KeyError) { root[long] }
    (error.message || "").bytesize.should be < 600
  end
end
