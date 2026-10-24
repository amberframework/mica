require "../spec_helper"

# Regression specs for the Codex code review of 2026-10-24 (findings 1-9).
describe "Codex review findings" do
  describe "1: namespace declarations on the DOM" do
    it "refuses to change a declaration that names in scope depend on" do
      document = Mica.parse(%(<r xmlns:p="u"><p:x/></r>))
      expect_raises(Mica::Error, /not supported/) { root_of(document)["xmlns:p"] = "v" }
      root_of(document)["xmlns:p"] = "u"
      document.xpath_nodes("//p:x", {"p" => "u"}).size.should eq(1)
    end

    it "refuses declarations that would rename nodes or break Namespaces 1.0" do
      document = Mica.parse(%(<r><x/></r>))
      expect_raises(Mica::Error, /rename existing nodes/) { root_of(document)["xmlns"] = "urn:d" }
      expect_raises(Mica::Error, /empty URI/) { root_of(document)["xmlns:q"] = "" }
      root_of(document)["xmlns:q"] = "urn:q"
      root_of(document)["q:a"] = "1"
      Mica.parse(root_of(document).to_xml).xpath_string("string(/r/@q:a)", {"q" => "urn:q"}).should eq("1")
    end

    it "refuses a second attribute with the same expanded name" do
      document = Mica.parse(%(<r xmlns:p="u" xmlns:q="u" p:a="1"/>))
      expect_raises(Mica::Error, /expanded name/) { root_of(document)["q:a"] = "2" }
    end
  end

  describe "2: builder namespaces and duplicates" do
    it "rejects unbound prefixes, invalid QNames and duplicate attributes" do
      expect_raises(Mica::BuilderError, /not declared/) { Mica.build(&.element("p:r")) }
      expect_raises(Mica::BuilderError, /Invalid qualified name/) { Mica.build(&.element("a:b:c")) }
      expect_raises(Mica::BuilderError, /written twice/) do
        Mica.build_fragment { |xml| xml.element("r") { xml.attribute("a", 1); xml.attribute("a", 2) } }
      end
      expect_raises(Mica::BuilderError, /expanded name/) do
        Mica.build_fragment do |xml|
          xml.element("r") do
            xml.namespace("p", "u")
            xml.namespace("q", "u")
            xml.attribute("p:a", 1)
            xml.attribute("q:a", 2)
          end
        end
      end
    end

    it "accepts a prefix declared after start_element on the same tag" do
      xml = Mica.build_fragment { |builder| builder.start_element("p:r"); builder.namespace("p", "urn:p"); builder.end_element }
      xml.should eq(%(<p:r xmlns:p="urn:p"/>))
      Mica.parse(xml)
    end
  end

  it "3: scans long name tokens across buffer compaction" do
    prefix = "<!--#{"x" * 60_000}--><!DOCTYPE r ["
    xml = prefix + "<!ATTLIST r a (" + "a" * prefix.bytesize + ") #IMPLIED>]><r/>"
    Mica.parse(IO::Memory.new(xml)).root.should_not be_nil
  end

  it "4: splits a ]]> that spans several CDATA writes" do
    xml = Mica.build_fragment { |builder| builder.element("r") { builder.cdata { builder.text("]]"); builder.text(">") } } }
    root_of(Mica.parse(xml)).content.should eq("]]>")
  end

  it "5: treats adjacent text and CDATA as one XPath text node" do
    document = Mica.parse(%(<r>a<![CDATA[b]]>c</r>))
    document.xpath_nodes("/r/text()").size.should eq(1)
    document.xpath_string("string(/r/text()[1])").should eq("abc")
    document.xpath_string("/r/text()").should eq("abc")
  end

  it "6: checks a declared UTF-16 byte order against the BOM" do
    xml = %(<?xml version="1.0" encoding="UTF-16BE"?><a/>)
    expect_raises(Mica::EncodingError, /byte order mark/) { Mica.parse(utf16(xml, false)) }
    Mica.parse(utf16(xml, true)).root.should_not be_nil
  end

  it "7: validates the version and DTD identifiers it writes" do
    expect_raises(Mica::BuilderError) { Mica.build(version: "1.0\" x=\"y", &.element("a")) }
    expect_raises(Mica::BuilderError) { Mica.build(&.dtd("a", "p\"q", "s")) }
    expect_raises(Mica::BuilderError) { Mica.build(&.dtd("a", nil, "a\"b'c")) }
    expect_raises(Mica::BuilderError) { Mica.build(&.dtd("a", nil, nil, "<!ENTITY")) }
    xml = Mica.build { |builder| builder.dtd("a", nil, %(a"b)); builder.element("a") }
    xml.should contain(%(SYSTEM 'a"b'))
    Mica.parse(xml)
  end

  it "8: bounds the height of long operator chains" do
    expect_raises(Mica::XPathError, /nested too deeply/) { Mica.parse("<a/>").xpath((["1"] * 5000).join(" + ")) }
    Mica.parse("<a/>").xpath_float((["1"] * 200).join(" + ")).should eq(200.0)
  end

  it "9: refuses to rename a PI to the reserved target xml" do
    document = Mica.parse("<a><?p d?></a>")
    expect_raises(Mica::Error, /reserved/) { node_at(document, "//processing-instruction()").name = "XmL" }
  end
end
