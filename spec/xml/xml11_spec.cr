require "../spec_helper"

private def parse11(body : String, options = Mica::XML::ParserOptions.default) : Mica::XML::Document
  Mica::XML.parse(%(<?xml version="1.1"?>) + body, options)
end

private def root_of(document : Mica::XML::Document) : Mica::XML::Node
  document.root || raise "document has no root element"
end

private def checking : Mica::XML::ParserOptions
  Mica::XML::ParserOptions.new(check_normalization: true)
end

describe "XML 1.1" do
  it_satisfies "XML11-2.11-line-ends", "normalizes NEL, LSEP, CR NEL and CR LF to LF in the document entity" do
    document = parse11("<a>1\u00852 3\r\u00854\r\n5\r6</a>")
    root_of(document).content.should eq("1\n2\n3\n4\n5\n6")
  end

  it_satisfies "XML11-2.11-line-ends", "keeps NEL and LSEP as characters in an XML 1.0 document" do
    document = Mica::XML.parse("<a>1\u00852 3</a>")
    root_of(document).content.should eq("1\u00852 3")
  end

  it_satisfies "XML11-2.11-line-ends", "counts NEL and LSEP as line ends in error positions" do
    error = expect_raises(Mica::ParseError) { parse11("<a>\u0085 <</a>") }
    error.line_number.should eq(3)
  end

  it_satisfies "XML11-4.1-char-refs", "accepts character references to C0 controls except NUL" do
    root_of(parse11("<a>&#1;&#x1F;&#12;</a>")).content.should eq("\u0001\u001F\f")
    expect_raises(Mica::ParseError, /illegal character/) { parse11("<a>&#0;</a>") }
    expect_raises(Mica::ParseError) { Mica::XML.parse("<a>&#1;</a>") }
  end

  it_satisfies "XML11-2.2-restricted-chars", "rejects literal C0, DEL and C1 controls and accepts their references" do
    expect_raises(Mica::ParseError) { parse11("<a>\u0001</a>") }
    expect_raises(Mica::ParseError) { parse11("<a>\u007F</a>") }
    expect_raises(Mica::ParseError) { parse11("<a>\u0086</a>") }
    expect_raises(Mica::ParseError) { parse11(%(<a b="\u0090"/>)) }
    root_of(parse11("<a>&#x7F;&#x86;</a>")).content.should eq("\u007F\u0086")
    root_of(Mica::XML.parse("<a>\u007F\u0086</a>")).content.should eq("\u007F\u0086")
  end

  it_satisfies "NS11-undeclare", "undeclares a prefix with an empty namespace name" do
    document = parse11(%(<p:a xmlns:p="urn:x"><b xmlns:p=""/></p:a>))
    root_of(document).namespace_uri.should eq("urn:x")
    expect_raises(Mica::ParseError) { parse11(%(<p:a xmlns:p="urn:x"><p:b xmlns:p=""/></p:a>)) }
    expect_raises(Mica::ParseError) { Mica::XML.parse(%(<p:a xmlns:p="urn:x"><b xmlns:p=""/></p:a>)) }
  end

  it_satisfies "XML11-2.13-normalization", "accepts fully normalized text when checking normalization" do
    document = parse11(%(<café a="été">résumé &#x301; ok<!-- é --><?pi é?></café>), checking)
    root_of(document).name.should eq("café")
  end

  it_satisfies "XML11-2.13-normalization", "rejects text that is not in NFC" do
    error = expect_raises(Mica::XML::NormalizationError, /character content .*Normalization Form C/) do
      parse11("<a>é</a>", checking)
    end
    error.line_number.should eq(1)
  end

  it_satisfies "XML11-2.13-normalization", "rejects constructs that start with a composing character" do
    expect_raises(Mica::XML::NormalizationError, /character content .*U\+0301/) { parse11("<a>́x</a>", checking) }
    expect_raises(Mica::XML::NormalizationError, /attribute value/) { parse11(%(<a b="́"/>), checking) }
    expect_raises(Mica::XML::NormalizationError, /CDATA section/) { parse11("<a><![CDATA[́]]></a>", checking) }
    expect_raises(Mica::XML::NormalizationError, /comment/) { parse11("<a><!--́--></a>", checking) }
    expect_raises(Mica::XML::NormalizationError, /character content/) { parse11("<a>x<b/>&#x301;</a>", checking) }
    expect_raises(Mica::XML::NormalizationError, /name/) { parse11("<á́/>".sub("á́", "aé"), checking) }
  end

  it_satisfies "XML11-2.13-normalization", "checks normalization only for XML 1.1 documents with the option on" do
    root_of(parse11("<a>é</a>")).content.should eq("é")
    root_of(Mica::XML.parse("<a>é</a>", checking)).content.should eq("é")
  end

  it_satisfies "XML11-2.13-normalization", "charges the normalization check to the work budget" do
    text = "é" * 10_000
    plain = Mica::Core::WorkMeter.new
    parse_meter = Mica::Core::WorkMeter.new
    Mica::XML.parse(%(<?xml version="1.1"?><a>#{text}</a>), meter: plain)
    Mica::XML.parse(%(<?xml version="1.1"?><a>#{text}</a>), checking, meter: parse_meter)
    (parse_meter.operations - plain.operations).should be >= text.bytesize * Mica::XML::Reader::NORMALIZATION_OPERATIONS_PER_BYTE
  end

  it_satisfies "XML11-4.3.4-version", "rejects an XML 1.1 declaration that is not 1.x" do
    expect_raises(Mica::ParseError) { Mica::XML.parse(%(<?xml version="2.0"?><a/>)) }
    Mica::XML.parse(%(<?xml version="1.7"?><a/>)).version.should eq("1.7")
  end

  it_satisfies "XML11-2.13-normalization", "reports a leading composing character at the start of the text" do
    error = expect_raises(Mica::XML::NormalizationError) { parse11("<a>\u0301x</a>", checking) }
    error.byte_offset.should eq(%(<?xml version="1.1"?><a>).bytesize)
    error.column_number.should eq(25)
  end

  it_satisfies "XML11-2.13-normalization", "checks declarations even when they are never used" do
    expect_raises(Mica::XML::NormalizationError, /entity replacement text/) do
      parse11(%(<!DOCTYPE a [<!ENTITY e "e\u0301">]><a/>), checking)
    end
    expect_raises(Mica::XML::NormalizationError, /name token/) do
      parse11(%(<!DOCTYPE a [<!ATTLIST a t (\u0301x|y) #IMPLIED>]><a/>), checking)
    end
    expect_raises(Mica::XML::NormalizationError, /attribute default value/) do
      parse11(%(<!DOCTYPE a [<!ATTLIST a t CDATA "e\u0301">]><a/>), checking)
    end
  end

  it_satisfies "XML11-4.1-char-refs", "keeps controls from character references in entity replacement text" do
    document = parse11(%(<!DOCTYPE a [<!ENTITY e "&#x1;&gt;&#x86;">]><a>&e;</a>))
    root_of(document).content.should eq("\u0001>\u0086")
    expect_raises(Mica::ParseError) { parse11("<!DOCTYPE a [<!ENTITY e \"\u0001\">]><a>&e;</a>") }
  end
end
