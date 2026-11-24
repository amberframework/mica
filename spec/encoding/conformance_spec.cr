require "json"
require "./support"

private alias Codec = Mica::Encoding::Codec
private alias ErrorMode = Mica::Encoding::ErrorMode

private def decode_fatal(bytes : Bytes, codec : Codec) : String
  Mica::Encoding.decode(bytes, codec, ErrorMode::Fatal)
end

private def code_points(text : String) : Array(Int32)
  text.chars.map(&.ord)
end

private SINGLE_BYTE_INDEXES = {
  Codec::IBM866 => "ibm866", Codec::ISO8859_2 => "iso-8859-2", Codec::ISO8859_3 => "iso-8859-3",
  Codec::ISO8859_4 => "iso-8859-4", Codec::ISO8859_5 => "iso-8859-5", Codec::ISO8859_6 => "iso-8859-6",
  Codec::ISO8859_7 => "iso-8859-7", Codec::ISO8859_8 => "iso-8859-8", Codec::ISO8859_8_I => "iso-8859-8",
  Codec::ISO8859_10 => "iso-8859-10", Codec::ISO8859_13 => "iso-8859-13", Codec::ISO8859_14 => "iso-8859-14",
  Codec::ISO8859_15 => "iso-8859-15", Codec::ISO8859_16 => "iso-8859-16", Codec::KOI8_R => "koi8-r",
  Codec::KOI8_U => "koi8-u", Codec::Macintosh => "macintosh", Codec::Windows874 => "windows-874",
  Codec::Windows1250 => "windows-1250", Codec::Windows1251 => "windows-1251", Codec::Windows1252 => "windows-1252",
  Codec::Windows1253 => "windows-1253", Codec::Windows1254 => "windows-1254", Codec::Windows1255 => "windows-1255",
  Codec::Windows1256 => "windows-1256", Codec::Windows1257 => "windows-1257", Codec::Windows1258 => "windows-1258",
  Codec::XMacCyrillic => "x-mac-cyrillic",
}

# The first pointer for each code point (the standard's "index pointer").
private def first_pointers(entries : Array({Int32, Int32})) : Hash(Int32, Int32)
  pointers = {} of Int32 => Int32
  entries.each { |pointer, code_point| pointers[code_point] = pointer unless pointers.has_key?(code_point) }
  pointers
end

describe "Mica::Encoding conformance" do
  it_satisfies "ENC-VECTORS-PINNED", "refuses a vector file whose sha256 does not match, naming it" do
    expect_raises(EncodingVectors::MismatchError, /whatwg\/index-nope\.txt is not pinned/) { EncodingVectors.read("whatwg/index-nope.txt") }
    EncodingVectors.read("whatwg/encodings.json").should_not be_empty
  end

  it_satisfies "ENC-LABELS", "resolves every label of encodings.json, padded and in any case, and nothing else" do
    checked = 0
    JSON.parse(EncodingVectors.read("whatwg/encodings.json")).as_a.each do |group|
      group["encodings"].as_a.each do |encoding|
        name = encoding["name"].as_s
        encoding["labels"].as_a.each do |label_value|
          label = label_value.as_s
          {label, label.upcase, " \t#{label}\n\f\r ", "\u{0B}#{label}"}.each_with_index do |variant, index|
            found = Mica::Encoding.lookup(variant)
            if index == 3
              found.should be_nil # U+000B is not ASCII whitespace
            else
              found.try(&.name).should eq(name)
            end
          end
          checked += 1
        end
      end
    end
    checked.should eq(Mica::Encoding::Tables::WEB_LABEL_COUNT)
    checked.should eq(228)
    Mica::Encoding.lookup("utf-7").should be_nil
    Mica::Encoding.lookup("").should be_nil
  end

  it_satisfies "ENC-LABEL-LIMIT", "refuses labels over 64 bytes before lookup" do
    padded = " " * 60 + "utf-8"
    padded.bytesize.should eq(65)
    Mica::Encoding.lookup(padded).should be_nil
    Mica::Encoding.lookup(" " * 59 + "utf-8").should eq(Codec::UTF8)
    Mica::Encoding.lookup("x" * 10_000).should be_nil
    expect_raises(Mica::Encoding::UnknownEncodingError, "Unknown encoding: #{"x" * 64}...") { Mica::Encoding.lookup!("x" * 10_000) }
  end

  it_satisfies "ENC-INDEX-DECODE", "decodes every single-byte index entry and encodes it back" do
    checked = 0
    SINGLE_BYTE_INDEXES.each do |codec, name|
      entries = EncodingVectors.index(name)
      firsts = first_pointers(entries)
      entries.each do |pointer, code_point|
        byte = (pointer + 0x80).to_u8
        code_points(decode_fatal(Bytes[byte], codec)).should eq([code_point])
        expected = (firsts[code_point] + 0x80).to_u8
        Mica::Encoding.encode(code_point.chr.to_s, codec).should eq(Bytes[expected])
        checked += 1
      end
      # Bytes without an entry are errors.
      (0...128).each do |pointer|
        next if entries.any? { |entry| entry[0] == pointer }
        expect_raises(Mica::Encoding::ConversionError) { decode_fatal(Bytes[(pointer + 0x80).to_u8], codec) }
      end
    end
    checked.should eq(3_434)
  end

  it_satisfies({"ENC-INDEX-DECODE", "ENC-INDEX-ENCODE", "ENC-CJK"}, "round-trips index jis0208 through EUC-JP, ISO-2022-JP and Shift_JIS") do
    entries = EncodingVectors.index("jis0208")
    firsts = first_pointers(entries)
    shift_jis_firsts = first_pointers(entries.reject { |pointer, _| 8272 <= pointer <= 8835 })
    entries.each do |pointer, code_point|
      text = code_point.chr.to_s
      if pointer < 94 * 94
        euc = Bytes[(pointer // 94 + 0xA1).to_u8, (pointer % 94 + 0xA1).to_u8]
        code_points(decode_fatal(euc, Codec::EUCJP)).should eq([code_point])
        jis = Bytes[0x1B, 0x24, 0x42, (pointer // 94 + 0x21).to_u8, (pointer % 94 + 0x21).to_u8, 0x1B, 0x28, 0x42]
        code_points(decode_fatal(jis, Codec::ISO2022JP)).should eq([code_point])
      end
      leading = pointer // 188
      trailing = pointer % 188
      sjis = Bytes[(leading + (leading < 0x1F ? 0x81 : 0xC1)).to_u8, (trailing + (trailing < 0x3F ? 0x40 : 0x41)).to_u8]
      code_points(decode_fatal(sjis, Codec::ShiftJIS)).should eq([code_point]) unless 8836 <= pointer <= 10715
      next if code_point == 0x2212 || (0xFF61..0xFF9F).includes?(code_point) || code_point == 0xA5 || code_point == 0x203E
      first = firsts[code_point]
      Mica::Encoding.encode(text, Codec::EUCJP).should eq(Bytes[(first // 94 + 0xA1).to_u8, (first % 94 + 0xA1).to_u8])
      if shift_first = shift_jis_firsts[code_point]?
        lead = shift_first // 188
        trail = shift_first % 188
        Mica::Encoding.encode(text, Codec::ShiftJIS).should eq(Bytes[(lead + (lead < 0x1F ? 0x81 : 0xC1)).to_u8, (trail + (trail < 0x3F ? 0x40 : 0x41)).to_u8])
      end
    end
    entries.size.should eq(7_724)
  end

  it_satisfies({"ENC-INDEX-DECODE", "ENC-CJK"}, "decodes every index jis0212 entry through EUC-JP") do
    entries = EncodingVectors.index("jis0212")
    entries.each do |pointer, code_point|
      bytes = Bytes[0x8F, (pointer // 94 + 0xA1).to_u8, (pointer % 94 + 0xA1).to_u8]
      code_points(decode_fatal(bytes, Codec::EUCJP)).should eq([code_point])
    end
    entries.size.should eq(6_067)
  end

  it_satisfies({"ENC-INDEX-DECODE", "ENC-INDEX-ENCODE", "ENC-CJK"}, "round-trips index EUC-KR") do
    entries = EncodingVectors.index("euc-kr")
    firsts = first_pointers(entries)
    entries.each do |pointer, code_point|
      bytes = Bytes[(pointer // 190 + 0x81).to_u8, (pointer % 190 + 0x41).to_u8]
      code_points(decode_fatal(bytes, Codec::EUCKR)).should eq([code_point])
      first = firsts[code_point]
      Mica::Encoding.encode(code_point.chr.to_s, Codec::EUCKR).should eq(Bytes[(first // 190 + 0x81).to_u8, (first % 190 + 0x41).to_u8])
    end
    entries.size.should eq(17_048)
  end

  it_satisfies({"ENC-INDEX-DECODE", "ENC-INDEX-ENCODE", "ENC-CJK"}, "round-trips index gb18030 and every gb18030 range through gb18030 and GBK") do
    entries = EncodingVectors.index("gb18030")
    firsts = first_pointers(entries)
    two_byte = ->(pointer : Int32) do
      trailing = pointer % 190
      Bytes[(pointer // 190 + 0x81).to_u8, (trailing + (trailing < 0x3F ? 0x40 : 0x41)).to_u8]
    end
    private_use = {0xE78D, 0xE78E, 0xE78F, 0xE790, 0xE791, 0xE792, 0xE793, 0xE794, 0xE795, 0xE796, 0xE81E, 0xE826, 0xE82B, 0xE82C, 0xE832, 0xE843, 0xE854, 0xE864}
    entries.each do |pointer, code_point|
      code_points(decode_fatal(two_byte.call(pointer), Codec::GB18030)).should eq([code_point])
      code_points(decode_fatal(two_byte.call(pointer), Codec::GBK)).should eq([code_point])
      next if code_point == 0xE5E5 || private_use.includes?(code_point)
      expected = two_byte.call(firsts[code_point])
      Mica::Encoding.encode(code_point.chr.to_s, Codec::GB18030).should eq(expected)
      Mica::Encoding.encode(code_point.chr.to_s, Codec::GBK).should eq(expected) unless code_point == 0x20AC
    end
    entries.size.should eq(23_940)
    private_use.each do |code_point|
      bytes = Mica::Encoding::GB18030Encoder.private_use_bytes(code_point) || fail "no bytes for #{code_point}"
      Mica::Encoding.encode(code_point.chr.to_s, Codec::GB18030).should eq(Bytes[bytes[0], bytes[1]])
      code_points(decode_fatal(Bytes[bytes[0], bytes[1]], Codec::GB18030)).should_not eq([code_point]) # asymmetric by design
    end
    expect_raises(Mica::Encoding::ConversionError, /U\+E5E5/) { Mica::Encoding.encode("\u{E5E5}", Codec::GB18030) }
    Mica::Encoding.encode("€", Codec::GBK).should eq(Bytes[0x80])

    ranges = EncodingVectors.index("gb18030-ranges")
    ranges.each do |pointer, code_point|
      four = Bytes[(pointer // 12600 + 0x81).to_u8, (pointer % 12600 // 1260 + 0x30).to_u8, (pointer % 1260 // 10 + 0x81).to_u8, (pointer % 10 + 0x30).to_u8]
      expected = pointer == 7457 ? 0xE7C7 : code_point
      code_points(decode_fatal(four, Codec::GB18030)).should eq([expected])
      Mica::Encoding.encode(expected.chr.to_s, Codec::GB18030).should eq(four) unless firsts.has_key?(expected)
      expect_raises(Mica::Encoding::ConversionError) { Mica::Encoding.encode(expected.chr.to_s, Codec::GBK) } unless firsts.has_key?(expected) || expected < 0x80
    end
    ranges.size.should eq(207)
    # The last four-byte code: U+10FFFF.
    Mica::Encoding.encode("\u{10FFFF}", Codec::GB18030).should eq(Bytes[0xE3, 0x32, 0x9A, 0x35])
  end

  it_satisfies({"ENC-INDEX-DECODE", "ENC-INDEX-ENCODE", "ENC-CJK"}, "round-trips index Big5 through Big5 and BIG5-HKSCS") do
    entries = EncodingVectors.index("big5")
    lasts = {0x2550, 0x255E, 0x2561, 0x256A, 0x5341, 0x5345}
    standard = entries.reject { |pointer, _| pointer < (0xA1 - 0x81) * 157 }
    expected_pointer = first_pointers(standard)
    lasts.each { |code_point| expected_pointer[code_point] = standard.select { |entry| entry[1] == code_point }.max_of(&.[0]) }
    bytes_for = ->(pointer : Int32) do
      trailing = pointer % 157
      Bytes[(pointer // 157 + 0x81).to_u8, (trailing + (trailing < 0x3F ? 0x40 : 0x62)).to_u8]
    end
    entries.each do |pointer, code_point|
      code_points(decode_fatal(bytes_for.call(pointer), Codec::Big5)).should eq([code_point])
      text = code_point.chr.to_s
      if standard_pointer = expected_pointer[code_point]?
        Mica::Encoding.encode(text, Codec::Big5).should eq(bytes_for.call(standard_pointer))
        Mica::Encoding.encode(text, Codec::Big5HKSCS).should eq(bytes_for.call(standard_pointer)) unless code_point == 0xCA || code_point == 0xEA
      else
        expect_raises(Mica::Encoding::ConversionError) { Mica::Encoding.encode(text, Codec::Big5) }
        Mica::Encoding.decode(Mica::Encoding.encode(text, Codec::Big5HKSCS), Codec::Big5HKSCS, ErrorMode::Fatal).should eq(text)
      end
    end
    entries.size.should eq(18_590)
    {1133 => "\u{CA}\u{304}", 1135 => "\u{CA}\u{30C}", 1164 => "\u{EA}\u{304}", 1166 => "\u{EA}\u{30C}"}.each do |pointer, text|
      decode_fatal(bytes_for.call(pointer), Codec::Big5).should eq(text)
      Mica::Encoding.encode(text, Codec::Big5HKSCS).should eq(bytes_for.call(pointer))
    end
  end

  it_satisfies "ENC-UTF8-SUBPART", "replaces ill-formed UTF-8 per maximal subpart (Unicode Table 3-8 and its neighbors)" do
    replacement = Mica::Encoding::ErrorMode::Replacement
    decode = ->(bytes : Bytes) { Mica::Encoding.decode(bytes, Codec::UTF8, replacement) }
    # Unicode 16.0 chapter 3, Table 3-8: 61 F1 80 80 E1 80 C2 62 80 63 80 BF 64
    decode.call(Bytes[0x61, 0xF1, 0x80, 0x80, 0xE1, 0x80, 0xC2, 0x62, 0x80, 0x63, 0x80, 0xBF, 0x64]).should eq("a\u{FFFD}\u{FFFD}\u{FFFD}b\u{FFFD}c\u{FFFD}\u{FFFD}d")
    # Tables 3-9 to 3-11: non-shortest forms, surrogates, and truncated sequences.
    decode.call(Bytes[0xC0, 0xAF, 0xE0, 0x80, 0xBF, 0xF0, 0x81, 0x82, 0x41]).should eq("\u{FFFD}" * 8 + "A")
    decode.call(Bytes[0xED, 0xA0, 0x80, 0xED, 0xBF, 0xBF, 0xED, 0xAF, 0x41]).should eq("\u{FFFD}" * 8 + "A")
    decode.call(Bytes[0xF4, 0x91, 0x92, 0x93, 0xFF, 0x41, 0x80, 0xBF, 0x42]).should eq("\u{FFFD}" * 5 + "A\u{FFFD}\u{FFFD}B")
    decode.call(Bytes[0xE1, 0x80, 0xE2, 0xF0, 0x91, 0x92, 0xF1, 0xBF, 0x41]).should eq("\u{FFFD}" * 4 + "A")
    decode.call(Bytes[0xF0, 0x9F, 0x98]).should eq("\u{FFFD}")
  end

  it_satisfies "ENC-UTF16", "decodes UTF-16 surrogate pairs and replaces what is unpaired" do
    Mica::Encoding.decode(Bytes[0x3D, 0xD8, 0x00, 0xDE], Codec::UTF16LE).should eq("😀")
    Mica::Encoding.decode(Bytes[0xD8, 0x3D, 0xDE, 0x00], Codec::UTF16BE).should eq("😀")
    Mica::Encoding.decode(Bytes[0x00, 0xD8, 0x61, 0x00], Codec::UTF16LE).should eq("\u{FFFD}a")
    Mica::Encoding.decode(Bytes[0x00, 0xDC, 0x61], Codec::UTF16LE).should eq("\u{FFFD}\u{FFFD}")
    Mica::Encoding.decode(Bytes[0x00, 0xD8], Codec::UTF16LE).should eq("\u{FFFD}")
    Mica::Encoding.decode(Bytes[0xFF, 0xFE, 0x61, 0x00], Codec::UTF16LE, strip_bom: true).should eq("a")
    Mica::Encoding.decode(Bytes[0xFF, 0xFE, 0x61, 0x00], Codec::UTF16LE).should eq("\u{FEFF}a")
  end

  it_satisfies "ENC-SINGLE-BYTE", "keeps exact ISO-8859-1, x-user-defined and US-ASCII apart from windows-1252" do
    Mica::Encoding.decode(Bytes[0x80, 0xFF], Codec::Windows1252).should eq("€ÿ")
    Mica::Encoding.decode(Bytes[0x80, 0xFF], Codec::ISO8859_1).should eq("\u{80}ÿ")
    Mica::Encoding.decode(Bytes[0x80, 0xFF], Codec::XUserDefined).should eq("\u{F780}\u{F7FF}")
    Mica::Encoding.encode("\u{F780}a", Codec::XUserDefined).should eq(Bytes[0x80, 0x61])
    Mica::Encoding.decode(Bytes[0x41, 0x80], Codec::USASCII).should eq("A\u{FFFD}")
    expect_raises(Mica::Encoding::ConversionError, /U\+20AC/) { Mica::Encoding.encode("€", Codec::ISO8859_1) }
  end

  it_satisfies "ENC-CJK", "follows the ISO-2022-JP escape rules of the standard" do
    jis = Codec::ISO2022JP
    Mica::Encoding.encode("¥¥", jis).should eq(Bytes[0x1B, 0x28, 0x4A, 0x5C, 0x5C, 0x1B, 0x28, 0x42])
    # Two escapes in a row with nothing between them is an error.
    Mica::Encoding.decode(Bytes[0x1B, 0x28, 0x4A, 0x1B, 0x28, 0x42, 0x61], jis).should eq("\u{FFFD}a")
    # An escape that is not one restores its bytes.
    Mica::Encoding.decode(Bytes[0x1B, 0x24, 0x61], jis).should eq("\u{FFFD}$a")
    expect_raises(Mica::Encoding::ConversionError) { Mica::Encoding.encode("\u{1B}", jis) }
    Mica::Encoding.encode("\u{1B}", jis, ErrorMode::Replacement).should eq("&#65533;".to_slice)
    Mica::Encoding.encode("ｱ", jis).should eq(Bytes[0x1B, 0x24, 0x42, 0x25, 0x22, 0x1B, 0x28, 0x42])
  end
end
