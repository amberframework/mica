require "../spec_helper"

describe Mica::Builder do
  describe "Mica.build" do
    it "writes a document with the declaration and a final newline" do
      Mica.build { |xml| xml.element("a") { } }.should eq(%(<?xml version="1.0"?>\n<a/>\n))
      Mica.build(encoding: "UTF-8", &.element("a", x: 1)).should eq(%(<?xml version="1.0" encoding="UTF-8"?>\n<a x="1"/>\n))
    end

    it "indents element-only content" do
      xml = Mica.build(indent: 2) do |builder|
        builder.element("feed") do
          builder.element("title") { builder.text "News" }
          builder.element("item", id: 1)
        end
      end
      xml.should eq(%(<?xml version="1.0"?>\n<feed>\n  <title>News</title>\n  <item id="1"/>\n</feed>\n))
    end

    it "escapes text and attribute values" do
      xml = Mica.build_fragment do |builder|
        builder.element("a", title: %(Tom & "Jerry" <3>\t\n\r)) { builder.text "1 < 2 & 3 > 2\r\n" }
      end
      xml.should eq(%(<a title="Tom &amp; &quot;Jerry&quot; &lt;3&gt;&#9;&#10;&#13;">1 &lt; 2 &amp; 3 &gt; 2&#13;\n</a>))
      document = Mica.parse(xml)
      root_of(document)["title"].should eq(%(Tom & "Jerry" <3>\t\n\r))
      root_of(document).content.should eq("1 < 2 & 3 > 2\r\n")
    end

    it "uses the chosen quote character" do
      Mica.build_fragment(quote_char: '\'') { |xml| xml.element("a", t: %(it's "x")) }.should eq(%(<a t='it&apos;s "x"'/>))
    end

    it "splits ]]> inside CDATA and writes comments, PIs-free DTDs" do
      xml = Mica.build do |builder|
        builder.dtd("a", nil, "a.dtd")
        builder.element("a") do
          builder.cdata("x]]>y")
          builder.comment(" note ")
        end
      end
      xml.should eq(%(<?xml version="1.0"?>\n<!DOCTYPE a SYSTEM "a.dtd"><a><![CDATA[x]]]]><![CDATA[>y]]><!-- note --></a>\n))
      root_of(Mica.parse(xml)).content.should eq("x]]>y")
    end

    it "declares namespaces once per scope" do
      xml = Mica.build_fragment do |builder|
        builder.element("s3", "List", "urn:s3") do
          builder.attribute("x", "a", "urn:x", "1")
          builder.element("s3", "Key", "urn:s3") { builder.text "k" }
        end
      end
      xml.should eq(%(<s3:List xmlns:s3="urn:s3" xmlns:x="urn:x" x:a="1"><s3:Key>k</s3:Key></s3:List>))
      Mica.parse(xml).xpath_string("string(//s:Key)", {"s" => "urn:s3"}).should eq("k")
    end

    it "supports the start/end API with attribute text" do
      io = IO::Memory.new
      builder = Mica::Builder.new(io)
      builder.start_element("a")
      builder.start_attribute("t")
      builder.text("x&y")
      builder.end_attribute
      builder.text("body")
      builder.end_element
      io.to_s.should eq(%(<a t="x&amp;y">body</a>))
    end
  end

  describe "misuse" do
    it "raises BuilderError or Error for malformed output" do
      expect_raises(Mica::Error) { Mica.build_fragment(&.element("bad name")) }
      expect_raises(Mica::Error) { Mica.build_fragment { |xml| xml.element("a") { xml.text "\u0000" } } }
      expect_raises(Mica::BuilderError) { Mica.build_fragment { |xml| xml.element("a") { xml.comment("x--y") } } }
      expect_raises(Mica::BuilderError) { Mica.build_fragment { |xml| xml.element("a") { xml.text "t"; xml.attribute("late", "1") } } }
      expect_raises(Mica::BuilderError) { Mica.build_fragment(&.end_element) }
      expect_raises(Mica::BuilderError) { Mica.build { |xml| xml.element("a"); xml.element("b") } }
      expect_raises(Mica::BuilderError) { Mica.build(encoding: "ISO-8859-1", &.element("a")) }
    end
  end

  describe "round trip" do
    it "parses builder output back to the same values" do
      random = Random.new(42)
      50.times do
        text = String.build { |io| 20.times { io << ['a', '<', '&', '>', '"', '\'', ' ', '\n', '\t', 'é', '😀', ']'].sample(random) } }
        xml = Mica.build { |builder| builder.element("r", v: text) { builder.text text; builder.cdata(text) } }
        root = root_of(Mica.parse(xml))
        root["v"].should eq(text)
        root.content.should eq(text + text)
      end
    end
  end
end
