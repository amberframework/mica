require "../spec_helper"

# The hostile-bytes matrix: every hostile byte class of
# Mica::Testing::ByteMutator, in every syntactic context, under XML 1.0 and
# XML 1.1, read from a byte slice and from a one-byte-at-a-time IO. Each
# cell must end in acceptance or a Mica::Error (never another exception),
# give the same outcome from both inputs, and, where the bytes are not
# allowed, report the exact error class and byte offset predicted by an
# independent oracle.
module HostileMatrix
  CONTEXTS = {
    "text"           => "<a>xHy</a>",
    "attribute"      => %(<a b="xHy"/>),
    "element name"   => "<aH/>",
    "comment"        => "<a><!--xHy--></a>",
    "PI data"        => "<a><?p xHy?></a>",
    "CDATA section"  => "<a><![CDATA[xHy]]></a>",
    "entity value"   => %(<!DOCTYPE a [<!ENTITY e "xHy">]><a>&e;</a>),
    "after the root" => "<a/><!--xHy-->",
  }

  # Contexts where the hostile sequence is character data (any Char is
  # allowed, so an oracle can predict acceptance exactly).
  CHARACTER_CONTEXTS = {"text", "attribute", "comment", "PI data", "CDATA section", "after the root"}

  VERSIONS = {"1.0" => "", "1.1" => %(<?xml version="1.1"?>)}

  record Cell, version : String, context : String, hostile_class : String, bytes : Bytes, offset : Int32

  def self.cells : Array(Cell)
    list_of_cells = [] of Cell
    VERSIONS.each do |version, declaration|
      CONTEXTS.each do |context, template|
        Mica::Testing::ByteMutator::HOSTILE.each do |hostile_class, list_of_samples|
          list_of_samples.each do |sample|
            head, tail = template.split('H', 2)
            prefix = (declaration + head).to_slice
            bytes = Bytes.new(prefix.size + sample.size + tail.bytesize)
            bytes[0, prefix.size].copy_from(prefix)
            bytes[prefix.size, sample.size].copy_from(sample)
            bytes[prefix.size + sample.size, tail.bytesize].copy_from(tail.to_slice)
            list_of_cells << Cell.new(version, context, hostile_class, bytes, prefix.size)
          end
        end
      end
    end
    list_of_cells
  end

  # The outcome of one parse: "ok" or the error class, message and offset.
  def self.outcome(source : Bytes | IO) : String
    document = Mica::XML.parse(source)
    "ok #{document.node_count}"
  rescue error : Mica::ParseError
    "#{error.class}|#{error.message}|#{error.byte_offset}"
  end

  # True when *code* may appear literally in character data.
  def self.literal_char?(code : Int32, version : String) : Bool
    return true if code == 0x9 || code == 0xA || code == 0xD
    return false if code < 0x20
    if version == "1.1"
      return false if (0x7F..0x84).includes?(code) || (0x86..0x9F).includes?(code)
    end
    (0x20..0xD7FF).includes?(code) || (0xE000..0xFFFD).includes?(code) || (0x10000..0x10FFFF).includes?(code)
  end

  # Returns the offset of the first code point in *sample* that is not
  # allowed literally, or nil. Decodes with the standard library's
  # Char::Reader, independently of Mica's decoder.
  def self.first_disallowed(sample : Bytes, version : String) : Int32?
    reader = Char::Reader.new(String.new(sample))
    while reader.has_next?
      return reader.pos if reader.error || !literal_char?(reader.current_char.ord, version)
      reader.next_char
    end
    nil
  end

  # Returns the offset of the first invalid UTF-8 sequence, or nil, from
  # the standard library's Char::Reader.
  def self.first_invalid(bytes : Bytes) : Int32?
    reader = Char::Reader.new(String.new(bytes))
    while reader.has_next?
      return reader.pos if reader.error
      reader.next_char
    end
    nil
  end
end

describe "Mica::XML hostile bytes matrix" do
  list_of_cells = HostileMatrix.cells

  it_satisfies "MICA-HOSTILE-MATRIX", "ends every cell in acceptance or a Mica::Error, identically from bytes and from a 1-byte IO" do
    list_of_cells.size.should be > 1_000
    list_of_cells.each do |cell|
      label = "#{cell.version} #{cell.context} #{cell.hostile_class} #{cell.bytes.hexstring}"
      from_bytes = HostileMatrix.outcome(cell.bytes)
      from_stream = HostileMatrix.outcome(TrickleIO.new(cell.bytes, 1))
      {label, from_stream}.should eq({label, from_bytes})
      {label, HostileMatrix.outcome(cell.bytes)}.should eq({label, from_bytes})
    end
  end

  it_satisfies({"MICA-HOSTILE-MATRIX", "XML10-4.3.3-encoding-errors"}, "reports invalid UTF-8 as an EncodingError at the first invalid byte") do
    checked = 0
    list_of_cells.each do |cell|
      invalid = HostileMatrix.first_invalid(cell.bytes)
      next unless invalid
      label = "#{cell.version} #{cell.context} #{cell.hostile_class} #{cell.bytes.hexstring}"
      error = expect_raises(Mica::ParseError) { Mica::XML.parse(cell.bytes) }
      # Valid characters before the invalid byte can end the parse first
      # (a NUL, or a byte that ends a name); otherwise the invalid byte is
      # what the parser reports.
      before = cell.bytes[cell.offset, invalid - cell.offset]
      if invalid == cell.offset || (HostileMatrix::CHARACTER_CONTEXTS.includes?(cell.context) && HostileMatrix.first_disallowed(before, cell.version).nil?)
        checked += 1
        {label, error.class}.should eq({label, Mica::EncodingError})
        {label, error.byte_offset}.should eq({label, invalid.to_i64})
      else
        {label, error.byte_offset <= invalid}.should eq({label, true})
      end
    end
    checked.should be > 300
  end

  it_satisfies({"MICA-HOSTILE-MATRIX", "XML10-2.2-Char", "XML11-2.2-restricted-chars"}, "rejects characters outside Char (and 1.1 restricted characters) at their exact offset") do
    checked = 0
    list_of_cells.each do |cell|
      next unless HostileMatrix::CHARACTER_CONTEXTS.includes?(cell.context)
      next if HostileMatrix.first_invalid(cell.bytes)
      sample = cell.bytes[cell.offset, cell.bytes.size - cell.offset - (HostileMatrix::CONTEXTS[cell.context].split('H', 2)[1].bytesize)]
      label = "#{cell.version} #{cell.context} #{cell.hostile_class} #{cell.bytes.hexstring}"
      if disallowed = HostileMatrix.first_disallowed(sample, cell.version)
        checked += 1
        error = expect_raises(Mica::ParseError) { Mica::XML.parse(cell.bytes) }
        {label, error.class}.should eq({label, Mica::ParseError})
        {label, error.byte_offset}.should eq({label, (cell.offset + disallowed).to_i64})
      else
        {label, HostileMatrix.outcome(cell.bytes).starts_with?("ok")}.should eq({label, true})
      end
    end
    checked.should be > 100
  end

  it_satisfies "MICA-HOSTILE-TRUNCATION", "rejects every proper prefix of a document, from bytes and from a stream" do
    latin1 = %(<?xml version="1.0" encoding="ISO-8859-1"?><r>).to_slice
    latin1_document = Bytes.new(latin1.size + 5)
    latin1_document[0, latin1.size].copy_from(latin1)
    latin1_document[latin1.size, 5].copy_from(Bytes[0xE9, 0x3C, 0x2F, 0x72, 0x3E])
    list_of_documents = [
      %(<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE r [<!ENTITY e "caf\u00E9 &#x1F600;">]><r a="1">&e;<b>\u20AC</b><![CDATA[x]]><!--c--><?p d?></r>).to_slice,
      %(<?xml version="1.1"?><r>\u0085\u2028&#1;</r>).to_slice,
      utf16(%(<r a="\u00E9">\u{1F600}</r>), big_endian: true),
      utf16(%(<r>x</r>), big_endian: false),
      latin1_document,
    ]
    list_of_documents.each do |document|
      HostileMatrix.outcome(document).should start_with("ok")
      (0...document.size).each do |length|
        prefix = document[0, length]
        from_bytes = HostileMatrix.outcome(prefix)
        {length, from_bytes.starts_with?("ok")}.should eq({length, false})
        {length, HostileMatrix.outcome(TrickleIO.new(prefix, 1))}.should eq({length, from_bytes})
      end
    end
  end
end
