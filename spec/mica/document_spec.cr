require "../spec_helper"

private SAMPLE = <<-XML
  <?xml version="1.0"?>
  <library xmlns="urn:lib" xmlns:x="urn:extra">
    <book id="1" x:rank="5"><title>Crystal</title><price>10</price></book>
    <book id="2"><title>Amber &amp; Grant</title><price>20</price></book>
    <!-- end -->
  </library>
  XML

describe Mica::Document do
  describe ".parse" do
    it "parses from String, Bytes and IO" do
      [Mica.parse(SAMPLE), Mica.parse(SAMPLE.to_slice), Mica.parse(IO::Memory.new(SAMPLE))].each do |document|
        document.root.try(&.name).should eq("library")
        document.version.should eq("1.0")
      end
    end
  end

  describe Mica::Node do
    it "navigates children, siblings and parents" do
      root = root_of(Mica.parse(SAMPLE))
      books = root.children.select(&.element?)
      books.map(&.["id"]).should eq(["1", "2"])
      first = books.first
      first.parent.should eq(root)
      first.next_element.should eq(books[1])
      books[1].previous_element.should eq(first)
      first.first_element_child.try(&.content).should eq("Crystal")
      root.children.count(&.comment?).should eq(1)
    end

    it "returns local names and namespace details like stdlib" do
      document = Mica.parse(%(<p:r xmlns:p="urn:p" p:a="1"/>))
      root = root_of(document)
      root.name.should eq("r")
      root.qualified_name.should eq("p:r")
      root.prefix.should eq("p")
      root.namespace_uri.should eq("urn:p")
      root.namespace.try(&.href).should eq("urn:p")
      root["p:a"].should eq("1")
      root["a"].should eq("1")
      root.attributes.map(&.name).should eq(["a"])
      root.namespaces.should eq({"xmlns:p" => "urn:p"})
      root.namespace_definitions.map(&.prefix).should eq(["p"])
    end

    it "returns content as concatenated descendant text" do
      root = root_of(Mica.parse(%(<a>x<b>y<![CDATA[z]]></b><!--no--></a>)))
      root.content.should eq("xyz")
      root.text.should eq("xyz")
      root.inner_text.should eq("xyz")
    end

    it "sets and deletes attributes" do
      document = Mica.parse(%(<a xmlns:p="urn:p" k="v"/>))
      root = root_of(document)
      root["k"] = "changed"
      root["new"] = 42
      root["p:q"] = "ns"
      root["k"].should eq("changed")
      root["new"].should eq("42")
      root.attributes["q"].namespace_uri.should eq("urn:p")
      root.delete("k").should eq("changed")
      root["k"]?.should be_nil
      expect_raises(Mica::Error) { root["zz:q"] = "x" }
      expect_raises(Mica::Error) { root["bad name"] = "x" }
      root.to_xml.should eq(%(<a xmlns:p="urn:p" new="42" p:q="ns"/>))
    end

    it "replaces content and renames elements" do
      document = Mica.parse(%(<a xmlns:p="urn:p"><b>old<c/></b></a>))
      element_to_change = node_at(document, "//b")
      element_to_change.content = "<new> & text"
      element_to_change.name = "p:renamed"
      element_to_change.namespace_uri.should eq("urn:p")
      root_of(document).to_xml(indent: 0).should eq(%(<a xmlns:p="urn:p"><p:renamed>&lt;new&gt; &amp; text</p:renamed></a>))
      expect_raises(Mica::Error) { element_to_change.name = "nope:x" }
    end

    it "unlinks nodes and keeps XPath and serialization consistent" do
      document = Mica.parse(%(<a><b>1</b><c>2</c><d>3</d></a>))
      node_at(document, "//c").unlink
      document.xpath_nodes("//*").map(&.name).should eq(["a", "b", "d"])
      root_of(document).content.should eq("13")
      root_of(document).to_xml(indent: 0).should eq("<a><b>1</b><d>3</d></a>")
      root = root_of(document)
      root["z"] = "1"
      node_at(root, "*[1]")["y"] = "2"
      document.xpath_nodes("//@*").map(&.name).should eq(["z", "y"])
    end

    it "keeps entity references that were not expanded" do
      document = Mica.parse(%(<!DOCTYPE a SYSTEM "a.dtd"><a>x&ext;y</a>))
      root_of(document).children.map(&.type).should eq([
        Mica::Node::Type::TEXT_NODE, Mica::Node::Type::ENTITY_REF_NODE, Mica::Node::Type::TEXT_NODE,
      ])
      root_of(document).to_xml.should eq("<a>x&ext;y</a>")
    end
  end

  describe "#to_xml" do
    it "writes the declaration, DOCTYPE and nodes" do
      xml = %(<!DOCTYPE a [<!ENTITY e "v">]><a b="&quot;1&quot;&#10;">t&amp;<![CDATA[x]]><?p d?><!--c--><e/></a>)
      Mica.parse(xml).to_xml.should eq(
        %(<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE a [<!ENTITY e "v">]>\n<a b="&quot;1&quot;&#10;">t&amp;<![CDATA[x]]><?p d?><!--c--><e/></a>\n))
    end

    it "indents element-only content and leaves mixed content alone" do
      document = Mica.parse("<a><b><c/></b><d>text <i>x</i></d></a>")
      root_of(document).to_xml.should eq("<a>\n  <b>\n    <c/>\n  </b>\n  <d>text <i>x</i></d>\n</a>")
      root_of(document).to_xml(indent: 0).should eq("<a><b><c/></b><d>text <i>x</i></d></a>")
    end

    it "round-trips: parse, serialize, parse gives the same tree" do
      [SAMPLE, %(<a x="&#9;&#10;&#13;&lt;&amp;&quot;">&#13;]]&gt;<![CDATA[]]]]><![CDATA[>]]></a>), %(<r><x:y xmlns:x="u" x:a="1"/>é😀</r>)].each do |xml|
        first = Mica.parse(xml)
        second = Mica.parse(first.to_xml(indent: 0))
        second.to_xml(indent: 0).should eq(first.to_xml(indent: 0))
        root_of(second).content.should eq(root_of(first).content)
      end
    end

    it "serializes very deep trees without recursion" do
      depth = 50_000
      xml = "<n>" * depth + "</n>" * depth
      document = Mica.parse(xml, Mica::ParserOptions.new(max_element_depth: depth + 1))
      expected = "<n>" * (depth - 1) + "<n/>" + "</n>" * (depth - 1)
      root_of(document).to_xml(indent: 0).should eq(expected)
    end
  end
end
