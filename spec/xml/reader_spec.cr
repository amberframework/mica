require "../spec_helper"

describe Mica::XML::Reader do
  describe "#read" do
    it_satisfies "XML10-3.1-tags", "walks elements, attributes, text and end tags" do
      reader_events(%(<a x="1"><b>hi</b><c/></a>)).should eq([
        %(ELEMENT:0:a @x="1"),
        %(ELEMENT:1:b),
        %(TEXT:2:#text="hi"),
        %(END_ELEMENT:1:b),
        %(ELEMENT:1:c),
        %(END_ELEMENT:0:a),
      ])
    end

    it_satisfies({"XML10-2.5-comments", "XML10-2.6-pi", "XML10-2.7-cdata", "XML10-2.8-doctype"}, "reports comments, PIs, CDATA and the DOCTYPE") do
      reader_events(%(<!DOCTYPE a><?go now?><a><!--c--><![CDATA[<x>]]></a><!--after-->)).should eq([
        %(DOCUMENT_TYPE:0:a),
        %(PROCESSING_INSTRUCTION:0:go="now"),
        %(ELEMENT:0:a),
        %(COMMENT:1:#comment="c"),
        %(CDATA:1:#cdata-section="<x>"),
        %(END_ELEMENT:0:a),
        %(COMMENT:0:#comment="after"),
      ])
    end

    it_satisfies "XML10-2.10-white-space", "reports whitespace-only text as SIGNIFICANT_WHITESPACE, like libxml2" do
      reader = Mica::XML::Reader.new("<a>\n  <b/>\n</a>")
      reader.read
      reader.read
      reader.node_type.should eq(Mica::XML::Reader::Type::SIGNIFICANT_WHITESPACE)
      reader.value.should eq("\n  ")
    end

    it_satisfies({"XML10-4.1-char-refs", "XML10-4.6-predefined-entities"}, "expands character and predefined entity references") do
      reader = Mica::XML::Reader.new(%(<a t="&lt;&#65;&#x42;">&amp;&gt;&apos;&quot;&#x1F600;</a>))
      reader.read
      reader["t"].should eq("<AB")
      reader.read
      reader.value.should eq("&>'\"😀")
    end

    it_satisfies({"XML10-2.11-line-ends", "XML10-3.3.3-attribute-normalization"}, "normalizes line ends and attribute white space") do
      reader = Mica::XML::Reader.new("<a t=\"x\ty\r\nz\">1\r\n2\r3</a>")
      reader.read
      reader["t"].should eq("x y z")
      reader.read
      reader.value.should eq("1\n2\n3")
    end

    it_satisfies "XML10-3.1-empty-element", "is empty_element? only for <x/>" do
      reader = Mica::XML::Reader.new("<a><b/><c></c></a>")
      reader.read
      reader.empty_element?.should be_false
      reader.read
      reader.empty_element?.should be_true
      reader.read
      reader.empty_element?.should be_false
    end

    it "returns false at the end and stays there" do
      reader = Mica::XML::Reader.new("<a/>")
      reader.read.should be_true
      reader.read.should be_false
      reader.read.should be_false
      reader.node_type.should eq(Mica::XML::Reader::Type::NONE)
    end
  end

  describe "attributes" do
    it "moves through attributes and back" do
      reader = Mica::XML::Reader.new(%(<a one="1" two='2'/>))
      reader.read
      reader.has_attributes?.should be_true
      reader.attributes_count.should eq(2)
      reader.move_to_first_attribute.should be_true
      reader.node_type.should eq(Mica::XML::Reader::Type::ATTRIBUTE)
      reader.name.should eq("one")
      reader.depth.should eq(1)
      reader.move_to_next_attribute.should be_true
      reader.value.should eq("2")
      reader.move_to_next_attribute.should be_false
      reader.move_to_element.should be_true
      reader.name.should eq("a")
      reader.move_to_attribute("two").should be_true
      reader.value.should eq("2")
      reader.move_to_attribute("three").should be_false
    end

    it "raises KeyError for a missing attribute with []" do
      reader = Mica::XML::Reader.new(%(<a/>))
      reader.read
      reader["x"]?.should be_nil
      expect_raises(KeyError) { reader["x"] }
    end
  end

  describe "namespaces" do
    it_satisfies "NS10-6-scoping", "resolves element and attribute namespaces" do
      reader = Mica::XML::Reader.new(%(<r xmlns="urn:d" xmlns:p="urn:p"><p:e p:a="1" b="2"/></r>))
      reader.read
      reader.namespace_uri.should eq("urn:d")
      reader.read
      reader.name.should eq("p:e")
      reader.local_name.should eq("e")
      reader.prefix.should eq("p")
      reader.namespace_uri.should eq("urn:p")
      reader.move_to_attribute("p:a")
      reader.namespace_uri.should eq("urn:p")
      reader.move_to_attribute("b")
      reader.namespace_uri.should be_nil
    end

    it_satisfies "NS10-6.2-default-undeclare", "lets xmlns=\"\" undeclare the default namespace" do
      reader = Mica::XML::Reader.new(%(<r xmlns="urn:d"><e xmlns=""/></r>))
      reader.read
      reader.read
      reader.namespace_uri.should be_nil
    end

    it_satisfies "NS10-6-scoping", "applies a DTD-defaulted xmlns before resolving names" do
      reader = Mica::XML::Reader.new(%(<!DOCTYPE r [<!ATTLIST r xmlns:p CDATA "urn:p">]><r><p:e/></r>))
      reader.read
      reader.read
      reader.read
      reader.namespace_uri.should eq("urn:p")
    end

    it_satisfies({"NS10-5-prefix-declared", "NS10-3-reserved-prefixes", "NS10-6.3-attribute-uniqueness"}, "rejects unbound prefixes, reserved bindings and duplicate expanded names") do
      [
        %(<p:a/>),
        %(<a xmlns:p=""/>),
        %(<a xmlns:xml="urn:other"/>),
        %(<a xmlns:xmlns="urn:x"/>),
        %(<a xmlns:p="http://www.w3.org/2000/xmlns/"/>),
        %(<a xmlns:p="urn:x" xmlns:q="urn:x" p:b="1" q:b="2"/>),
        %(<xmlns:a/>),
        %(<a:b:c xmlns:a="urn:a"/>),
      ].each do |xml|
        expect_raises(Mica::ParseError) { reader_events(xml) }
      end
    end

    it "accepts colons freely when namespace processing is off" do
      options = Mica::XML::ParserOptions.new(namespace_aware: false)
      reader_events(%(<a:b:c x:y="1"/>), options).should eq([%(ELEMENT:0:a:b:c @x:y="1")])
    end
  end

  describe "entities" do
    it_satisfies "XML10-4.3.2-balanced-entities", "expands internal entities with markup and checks balance" do
      xml = %(<!DOCTYPE r [<!ENTITY e "<b>x</b>&amp;">]><r>1&e;2</r>)
      reader_events(xml).should eq([
        %(DOCUMENT_TYPE:0:r),
        %(ELEMENT:0:r),
        %(TEXT:1:#text="1"),
        %(ELEMENT:1:b),
        %(TEXT:2:#text="x"),
        %(END_ELEMENT:1:b),
        %(TEXT:1:#text="&"),
        %(TEXT:1:#text="2"),
        %(END_ELEMENT:0:r),
      ])
    end

    it_satisfies "XML10-4.3.2-balanced-entities", "rejects an entity whose replacement text is not balanced" do
      expect_raises(Mica::ParseError, /ends inside element/) do
        reader_events(%(<!DOCTYPE r [<!ENTITY e "<b>">]><r>&e;</b></r>))
      end
    end

    it_satisfies "XML10-4.1-no-recursion", "rejects recursive entities" do
      expect_raises(Mica::ParseError, /Recursive/) do
        reader_events(%(<!DOCTYPE r [<!ENTITY a "&b;"><!ENTITY b "&a;">]><r>&a;</r>))
      end
    end

    it_satisfies "XML10-4.1-entity-declared", "rejects undeclared entities in a document without external declarations" do
      expect_raises(Mica::ParseError, /not declared/) { reader_events(%(<r>&nope;</r>)) }
    end

    it_satisfies "MICA-NO-EXTERNAL", "reports, but never fetches, external entities" do
      xml = %(<!DOCTYPE r [<!ENTITY ext SYSTEM "file:///etc/passwd">]><r>&ext;</r>)
      reader_events(xml).should eq([
        %(DOCUMENT_TYPE:0:r),
        %(ELEMENT:0:r),
        %(ENTITY_REFERENCE:1:ext),
        %(END_ELEMENT:0:r),
      ])
    end

    it_satisfies "XML10-3.1-no-external-in-attributes", "rejects an external entity inside an attribute value" do
      expect_raises(Mica::ParseError, /External entity/) do
        reader_events(%(<!DOCTYPE r [<!ENTITY ext SYSTEM "x.txt">]><r a="&ext;"/>))
      end
    end

    it_satisfies "XML10-4.1-entity-declared", "skips undeclared entities when the DTD has an external subset" do
      reader_events(%(<!DOCTYPE r SYSTEM "r.dtd"><r>&unknown;</r>)).should contain(%(ENTITY_REFERENCE:1:unknown))
    end

    it_satisfies "XML10-5.1-non-validating", "stops processing declarations after an unread parameter entity unless standalone" do
      xml = %(<!DOCTYPE r [<!ENTITY % ext SYSTEM "x.dtd">%ext;<!ATTLIST r a CDATA "d">]><r/>)
      reader = Mica::XML::Reader.new(xml)
      reader.read
      reader.read
      reader["a"]?.should be_nil

      standalone = %(<?xml version="1.0" standalone="yes"?>) + xml
      reader = Mica::XML::Reader.new(standalone)
      reader.read
      reader.read
      reader["a"].should eq("d")
    end

    it_satisfies "XML10-2.8-parameter-entities", "expands internal parameter entities between declarations" do
      xml = %(<!DOCTYPE r [<!ENTITY % decl "<!ENTITY g 'from-pe'>">%decl;]><r>&g;</r>)
      reader = Mica::XML::Reader.new(xml)
      reader.read
      reader.read
      reader.read
      reader.value.should eq("from-pe")
    end

    it_satisfies({"XML10-3.3-attlist", "XML10-3.3.2-defaults"}, "applies ATTLIST defaults and tokenized normalization") do
      xml = %(<!DOCTYPE r [<!ATTLIST r d CDATA "def" t NMTOKENS #IMPLIED>]><r t="  a   b "/>)
      reader = Mica::XML::Reader.new(xml)
      reader.read
      reader.read
      reader["d"].should eq("def")
      reader["t"].should eq("a b")
    end
  end

  describe "errors" do
    it_satisfies "MICA-ERROR-POSITION", "reports line and column of the first error" do
      # The mismatched end tag is reported at its name.
      error = expect_raises(Mica::ParseError) { reader_events("<a>\n  <b>\n</a>") }
      error.line_number.should eq(3)
      error.column_number.should eq(3)
    end

    it_satisfies "MICA-ERROR-POSITION", "counts columns in characters" do
      error = expect_raises(Mica::ParseError) { reader_events("<a>éé<</a>") }
      error.line_number.should eq(1)
      error.column_number.should eq(7)
    end

    it_satisfies "XML10-2.1-well-formed", "rejects common well-formedness errors" do
      [
        "", "<a>", "<a></b>", "<a/><b/>", "text", "<a>]]></a>", "<a b=1/>", "<a b='<'/>",
        "<a b='1' b='2'/>", "<a><!-- -- --></a>", "<?xml version='1.0'?><?xml version='1.0'?><a/>",
        "<a>&#0;</a>", "<a>\u0001</a>", "<!DOCTYPE a [<![INCLUDE[]]>]><a/>", "<a/>&amp;",
        "<?XML version='1.0'?><a/>", "<a>&#xD800;</a>", "<a></a>\u0000",
      ].each do |xml|
        expect_raises(Mica::ParseError) { reader_events(xml) }
      end
    end

    it_satisfies "XML10-4.3.3-encoding-errors", "rejects invalid UTF-8 with an EncodingError" do
      expect_raises(Mica::EncodingError) { reader_events(String.new(Bytes[0x3C, 0x61, 0x3E, 0xC3, 0x28, 0x3C, 0x2F, 0x61, 0x3E])) }
      expect_raises(Mica::EncodingError) { reader_events(String.new(Bytes[0x3C, 0x61, 0x3E, 0xED, 0xA0, 0x80, 0x3C, 0x2F, 0x61, 0x3E])) }
    end
  end

  describe "encodings" do
    it_satisfies "XML10-4.3.3-utf16", "reads UTF-16 big and little endian with a byte order mark" do
      text = %(<?xml version="1.0" encoding="UTF-16"?><a b="é">x😀</a>)
      [true, false].each do |big_endian|
        reader = Mica::XML::Reader.new(utf16(text, big_endian))
        reader.read
        reader["b"].should eq("é")
        reader.read
        reader.value.should eq("x😀")
        reader.encoding.should eq("UTF-16")
      end
    end

    it "reads UTF-16 from a trickling IO" do
      bytes = utf16(%(<a>#{"long text " * 100}</a>), false)
      reader = Mica::XML::Reader.new(TrickleIO.new(bytes, 3))
      reader.read
      reader.read
      reader.value.should eq("long text " * 100)
    end

    it_satisfies "XML10-4.3.3-byte-order-mark", "skips a UTF-8 byte order mark" do
      reader = Mica::XML::Reader.new(String.new(Bytes[0xEF, 0xBB, 0xBF] + "<a/>".to_slice))
      reader.read.should be_true
      reader.name.should eq("a")
    end

    it_satisfies "XML10-4.3.3-encoding-errors", "raises a clear EncodingError for other declared encodings" do
      error = expect_raises(Mica::EncodingError) { reader_events(%(<?xml version="1.0" encoding="Shift_JIS"?><a/>)) }
      error.message.to_s.should contain("Unsupported encoding 'Shift_JIS'")
    end

    it_satisfies "XML10-4.3.3-encoding-declaration", "decodes ISO-8859-1 after the declaration, from bytes and from a stream" do
      latin1 = %(<?xml version="1.0" encoding="ISO-8859-1"?><a t="caf\xE9">na\xEFve</a>).to_slice
      [Mica::XML::Reader.new(latin1), Mica::XML::Reader.new(TrickleIO.new(latin1, 3))].each do |reader|
        reader_events(reader).should eq([%(ELEMENT:0:a @t="café"), %(TEXT:1:#text="naïve"), "END_ELEMENT:0:a"])
      end
    end

    it_satisfies "XML10-4.3.3-utf16", "rejects UTF-16 without a byte order mark and a UTF-16 declaration on UTF-8 bytes" do
      bom_less = utf16("<?xml version='1.0'?><a/>", true)[2..]
      expect_raises(Mica::EncodingError, /byte order mark/) { reader_events(String.new(bom_less)) }
      expect_raises(Mica::EncodingError) { reader_events(%(<?xml version="1.0" encoding="UTF-16"?><a/>)) }
    end

    it_satisfies "XML10-4.3.3-encoding-declaration", "validates bytes against a US-ASCII declaration" do
      reader_events(%(<?xml version="1.0" encoding="US-ASCII"?><a>ok</a>)).size.should eq(3)
      expect_raises(Mica::EncodingError) { reader_events(%(<?xml version="1.0" encoding="US-ASCII"?><a>é</a>)) }
    end
  end

  describe "streaming" do
    it_satisfies "MICA-STREAM-EQUIVALENCE", "produces the same events from a String and from a 1-7 byte trickle" do
      xml = %(<?xml version="1.0"?>\r\n<!DOCTYPE r [<!ENTITY e "<i>e</i>"><!ATTLIST r d CDATA "x">]>) +
            %(<r xmlns:p="urn:p" a="1 &amp; 2"><p:b>t&e;ext</p:b><![CDATA[cd]]><!--c--><?pi d?>é😀\r\n</r>)
      expected = reader_events(xml)
      (1..7).each do |chunk|
        reader_events(Mica::XML::Reader.new(TrickleIO.new(xml.to_slice, chunk))).should eq(expected)
      end
    end

    it "streams a large document with a small buffer footprint" do
      io = IO::Memory.new
      io << "<list>"
      20_000.times { |index| io << "<item n=\"" << index << "\">value " << index << "</item>" }
      io << "</list>"
      io.rewind
      reader = Mica::XML::Reader.new(io)
      count = 0
      while reader.read
        count += 1 if reader.node_type.element?
      end
      count.should eq(20_001)
    end
  end

  describe "#next and #next_sibling" do
    it "skips subtrees" do
      reader = Mica::XML::Reader.new("<a><b><c/></b><d/></a>")
      reader.read
      reader.read
      reader.name.should eq("b")
      reader.next.should be_true
      reader.name.should eq("d")
    end

    it "moves to the next sibling" do
      reader = Mica::XML::Reader.new("<a><b><x/></b>text<d/></a>")
      reader.read
      reader.read
      reader.next_sibling.should be_true
      reader.node_type.should eq(Mica::XML::Reader::Type::TEXT)
      reader.next_sibling.should be_true
      reader.name.should eq("d")
      reader.next_sibling.should be_false
    end
  end

  describe "#expand" do
    it "returns the element subtree and leaves the reader on its end" do
      reader = Mica::XML::Reader.new(%(<feed><item id="1"><t>one</t></item><item id="2"/></feed>))
      reader.read
      reader.read
      item = reader.expand
      item["id"].should eq("1")
      item.xpath_string("string(t)").should eq("one")
      reader.node_type.should eq(Mica::XML::Reader::Type::END_ELEMENT)
      reader.read
      reader["id"].should eq("2")
    end

    it "serializes inner and outer XML" do
      reader = Mica::XML::Reader.new(%(<a><b x="1">t<c/></b></a>))
      reader.read
      reader.read
      reader.read_outer_xml.should eq(%(<b x="1">t<c/></b>))
      reader = Mica::XML::Reader.new(%(<a><b x="1">t<c/></b></a>))
      reader.read
      reader.read_inner_xml.should eq(%(<b x="1">t<c/></b>))
    end
  end
end
