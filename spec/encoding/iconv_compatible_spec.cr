require "./support"

private alias Codec = Mica::Encoding::Codec
private alias ErrorMode = Mica::Encoding::ErrorMode

private def iconv(name : String) : Codec
  Mica::Encoding.lookup!(name, Mica::Encoding::LabelRule::IconvCompatible)
end

describe "Mica::Encoding iconv-compatible names" do
  it_satisfies "ENC-ICONV-NAMES", "keeps iconv's meanings where they differ from the web's" do
    iconv("ISO-8859-1").should eq(Codec::ISO8859_1)
    iconv("latin1").should eq(Codec::ISO8859_1)
    iconv("ascii").should eq(Codec::USASCII)
    iconv("UTF-16").should eq(Codec::UTF16)
    iconv("UCS-2LE").should eq(Codec::UCS2LE)
    iconv("UTF-32").should eq(Codec::UTF32)
    iconv("BIG5-HKSCS").should eq(Codec::Big5HKSCS)
    iconv("Shift_JIS").should eq(Codec::ShiftJIS)
    iconv("CP1252").should eq(Codec::Windows1252)
    {"ISO-2022-CN-EXT", "ISO-2022-KR", "HZ-GB-2312", "replacement", "UTF-7", "FOO"}.each do |name|
      Mica::Encoding.lookup(name, Mica::Encoding::LabelRule::IconvCompatible).should be_nil
    end
    Mica::Encoding.lookup("ISO-2022-CN-EXT").should eq(Codec::Replacement)
  end

  it_satisfies "ENC-ICONV-NAMES", "matches the standard library's String#encode examples" do
    Mica::Encoding.encode("Hello", iconv("UCS-2LE")).should eq(Bytes[72, 0, 101, 0, 108, 0, 108, 0, 111, 0])
    Mica::Encoding.encode("\u{00CA}", iconv("BIG5-HKSCS")).should eq(Bytes[0x88, 0x66])
    Mica::Encoding.encode("\u{00CA}\u{0304}", iconv("BIG5-HKSCS")).should eq(Bytes[0x88, 0x62])
    Mica::Encoding.decode(Bytes[0x88, 0x66], iconv("BIG5-HKSCS")).should eq("\u{00CA}")
    Mica::Encoding.decode(Bytes[0x88, 0x62], iconv("BIG5-HKSCS")).should eq("\u{00CA}\u{0304}")
    expect_raises(Mica::Encoding::ConversionError, /invalid byte sequence/) { Mica::Encoding.encode("\xff", iconv("EUC-JP")) }
    Mica::Encoding.encode("好\xff是", iconv("EUC-JP"), ErrorMode::Skip).should eq(Bytes[185, 165, 192, 167])
    expect_raises(Mica::Encoding::ConversionError, /incomplete/) { Mica::Encoding.encode("好".byte_slice(0, 1), iconv("EUC-JP")) }
    Mica::Encoding.encode("好".byte_slice(0, 1) + "是", iconv("EUC-JP"), ErrorMode::Skip).should eq(Bytes[192, 167])
    Mica::Encoding.decode(Bytes[186, 195, 255, 202, 199], iconv("EUC-JP"), ErrorMode::Skip).should eq("挫頁")
  end

  it_satisfies "ENC-ICONV-NAMES", "reads and writes byte order marks for UTF-16 and UTF-32 (little-endian, as glibc), and none for the rest" do
    Mica::Encoding.encode("aé", Codec::UTF16).should eq(Bytes[0xFF, 0xFE, 0x61, 0, 0xE9, 0])
    Mica::Encoding.encode("a", Codec::UTF32).should eq(Bytes[0xFF, 0xFE, 0, 0, 0x61, 0, 0, 0])
    Mica::Encoding.decode(Bytes[0xFF, 0xFE, 0x61, 0], Codec::UTF16).should eq("a")
    Mica::Encoding.decode(Bytes[0xFE, 0xFF, 0, 0x61], Codec::UTF16).should eq("a")
    Mica::Encoding.decode(Bytes[0x61, 0], Codec::UTF16).should eq("a")
    Mica::Encoding.decode(Bytes[0xFF, 0xFE, 0, 0, 0x61, 0, 0, 0], Codec::UTF32).should eq("a")
    Mica::Encoding.decode(Bytes[0, 0, 0xFE, 0xFF, 0, 0, 0, 0x61], Codec::UTF32).should eq("a")
    Mica::Encoding.decode(Bytes[0x61, 0, 0, 0], Codec::UTF32).should eq("a")
    Mica::Encoding.decode(Bytes[0xFF, 0xFE, 0x61, 0], Codec::UTF16LE).should eq("\u{FEFF}a")
    Mica::Encoding.encode("\u{FEFF}a", Codec::UTF16LE).should eq(Bytes[0xFF, 0xFE, 0x61, 0])
    Mica::Encoding.encode("aé", Codec::UCS2).should eq(Bytes[0x61, 0, 0xE9, 0])
    expect_raises(Mica::Encoding::ConversionError, /U\+1F600/) { Mica::Encoding.encode("😀", Codec::UCS2) }
    Mica::Encoding.decode(Bytes[0x3D, 0xD8, 0x00, 0xDE], Codec::UCS2LE).should eq("\u{FFFD}\u{FFFD}")
    Mica::Encoding.decode(Bytes[0, 0x11, 0, 0], Codec::UTF32BE).should eq("\u{FFFD}")
  end
end
