require "../spec_helper"
require "../../src/mica/xml/fields"

private NO_DTD = Mica::XML::ParserOptions.new(allow_document_type: false)

private def utf16le_with_bom(text : String) : Bytes
  encoded = text.encode("UTF-16LE")
  bytes = Bytes.new(encoded.size + 2)
  bytes[0] = 0xFF_u8
  bytes[1] = 0xFE_u8
  encoded.copy_to(bytes + 2)
  bytes
end

private def read_all(source : String | Bytes) : Nil
  reader = Mica::XML::Reader.new(source, NO_DTD)
  while reader.read
  end
end

describe "ParserOptions#allow_document_type" do
  prolog_doctype = %(<?xml version="1.0"?><!--c--><?p x?><!DOCTYPE r><r/>)

  it "is true by default, so existing callers keep reading DTDs" do
    Mica::XML::ParserOptions.new.allow_document_type?.should be_true
    Mica::XML.parse(%(<!DOCTYPE r [<!ENTITY a "x">]><r>&a;</r>)).root.try(&.content).should eq("x")
  end

  it "keeps the existing positional parameters in place" do
    options = Mica::XML::ParserOptions.new(true, 1)
    options.max_entity_expansions.should eq(1)
  end

  it "refuses a DOCTYPE after an XML declaration, a comment and a PI, in the reader and the DOM" do
    error = expect_raises(Mica::XML::DocumentTypeNotAllowedError) { read_all(prolog_doctype) }
    error.byte_offset.should eq(prolog_doctype.index!("<!DOCTYPE"))

    expect_raises(Mica::XML::DocumentTypeNotAllowedError) { Mica::XML.parse(prolog_doctype, NO_DTD) }
  end

  it "refuses a DOCTYPE after a UTF-8 byte order mark" do
    expect_raises(Mica::XML::DocumentTypeNotAllowedError) { read_all("﻿" + prolog_doctype) }
  end

  it "refuses a DOCTYPE in BOM-marked UTF-16 input" do
    source = utf16le_with_bom(%(<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE r><r/>))

    expect_raises(Mica::XML::DocumentTypeNotAllowedError) { read_all(source) }
    expect_raises(Mica::XML::DocumentTypeNotAllowedError) { Mica::XML.parse(source, NO_DTD) }
  end

  it "reports a malformed <!DOCTYPE as a syntax error, not a refused DTD" do
    error = expect_raises(Mica::ParseError) { read_all(%(<!DOCTYPEx><r/>)) }
    error.is_a?(Mica::XML::DocumentTypeNotAllowedError).should be_false

    expect_raises(Mica::ParseError) { Mica::XML::Fields.read(%(<!DOCTYPEx><r/>)) }
  end

  it "still reads a document without a DOCTYPE" do
    Mica::XML.parse(%(<?xml version="1.0"?><r>ok</r>), NO_DTD).root.try(&.content).should eq("ok")
  end

  it "is a parse error, so callers rescuing Mica::ParseError still catch it" do
    expect_raises(Mica::ParseError) { read_all(prolog_doctype) }
  end
end
