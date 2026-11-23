module Mica::Encoding
  # Labels longer than this many bytes are refused before lookup. The
  # longest label either rule knows is under 20 bytes.
  MAX_LABEL_BYTES = 64

  # Names whose iconv meaning `LabelRule::IconvCompatible` keeps, already
  # trimmed and ASCII-lowercased. Names not listed here fall through to
  # the Encoding Standard's labels (minus replacement's), which already
  # cover `Shift_JIS`, `EUC-JP`, `GBK`, `windows-1252`, `KOI8-R` and so on
  # under their usual iconv spellings.
  ICONV_NAMES = {
    "utf-8" => Codec::UTF8, "utf8" => Codec::UTF8,
    "utf-16" => Codec::UTF16, "utf16" => Codec::UTF16, "unicode" => Codec::UTF16,
    "utf-16be" => Codec::UTF16BE, "utf16be" => Codec::UTF16BE,
    "utf-16le" => Codec::UTF16LE, "utf16le" => Codec::UTF16LE,
    "utf-32" => Codec::UTF32, "utf32" => Codec::UTF32,
    "utf-32be" => Codec::UTF32BE, "utf32be" => Codec::UTF32BE, "ucs-4" => Codec::UTF32BE,
    "ucs4" => Codec::UTF32BE, "ucs-4be" => Codec::UTF32BE, "iso-10646-ucs-4" => Codec::UTF32BE,
    "utf-32le" => Codec::UTF32LE, "utf32le" => Codec::UTF32LE, "ucs-4le" => Codec::UTF32LE,
    "ucs-2" => Codec::UCS2, "ucs2" => Codec::UCS2, "iso-10646-ucs-2" => Codec::UCS2, "csunicode" => Codec::UCS2,
    "ucs-2be" => Codec::UCS2BE, "ucs2be" => Codec::UCS2BE, "unicodebig" => Codec::UCS2BE,
    "ucs-2le" => Codec::UCS2LE, "ucs2le" => Codec::UCS2LE, "unicodelittle" => Codec::UCS2LE,
    "ascii" => Codec::USASCII, "us-ascii" => Codec::USASCII, "ansi_x3.4-1968" => Codec::USASCII,
    "ansi_x3.4-1986" => Codec::USASCII, "iso646-us" => Codec::USASCII, "iso_646.irv:1991" => Codec::USASCII,
    "iso-ir-6" => Codec::USASCII, "us" => Codec::USASCII, "646" => Codec::USASCII, "csascii" => Codec::USASCII,
    "cp367" => Codec::USASCII, "ibm367" => Codec::USASCII,
    "iso-8859-1" => Codec::ISO8859_1, "iso8859-1" => Codec::ISO8859_1, "iso_8859-1" => Codec::ISO8859_1,
    "iso88591" => Codec::ISO8859_1, "iso_8859-1:1987" => Codec::ISO8859_1, "8859_1" => Codec::ISO8859_1,
    "latin1" => Codec::ISO8859_1, "l1" => Codec::ISO8859_1, "cp819" => Codec::ISO8859_1,
    "ibm819" => Codec::ISO8859_1, "iso-ir-100" => Codec::ISO8859_1, "csisolatin1" => Codec::ISO8859_1,
    "big5-hkscs" => Codec::Big5HKSCS, "big5hkscs" => Codec::Big5HKSCS,
    "cp936" => Codec::GBK, "euc-cn" => Codec::GBK, "euccn" => Codec::GBK,
    "cp949" => Codec::EUCKR, "uhc" => Codec::EUCKR, "cp950" => Codec::Big5,
    "eucjp" => Codec::EUCJP, "euckr" => Codec::EUCKR, "macroman" => Codec::Macintosh,
  }

  # Returns the encoding *label* names under *rule*, or nil when the rule
  # does not know it. Leading and trailing ASCII whitespace is ignored and
  # ASCII letters match in either case, as the Encoding Standard's "get an
  # encoding" says. A label over `MAX_LABEL_BYTES` bytes returns nil
  # without being examined further.
  #
  # ```
  # Mica::Encoding.lookup(" Latin1 ")                           # => Mica::Encoding::Codec::Windows1252
  # Mica::Encoding.lookup("latin1", :iconv_compatible)          # => Mica::Encoding::Codec::ISO8859_1
  # Mica::Encoding.lookup("ISO-2022-CN-EXT")                    # => Mica::Encoding::Codec::Replacement
  # Mica::Encoding.lookup("ISO-2022-CN-EXT", :iconv_compatible) # => nil
  # ```
  def self.lookup(label : String, rule : LabelRule = LabelRule::Web) : Codec?
    return if label.bytesize > MAX_LABEL_BYTES
    key = normalize_label(label)
    if rule.web?
      Tables::WEB_LABELS[key]?
    elsif codec = ICONV_NAMES[key]?
      codec
    elsif codec = Tables::WEB_LABELS[key]?
      codec unless codec.replacement?
    end
  end

  # Like `lookup`, but raises `UnknownEncodingError` for a label the rule
  # does not know.
  def self.lookup!(label : String, rule : LabelRule = LabelRule::Web) : Codec
    lookup(label, rule) || raise UnknownEncodingError.new(label)
  end

  # Trims ASCII whitespace (TAB, LF, FF, CR, SPACE) and lowercases ASCII
  # letters.
  private def self.normalize_label(label : String) : String
    bytes = label.to_slice
    start = 0
    finish = bytes.size
    while start < finish && ascii_whitespace?(bytes[start])
      start += 1
    end
    while finish > start && ascii_whitespace?(bytes[finish - 1])
      finish -= 1
    end
    String.new(finish - start) do |buffer|
      (start...finish).each_with_index do |source, target|
        byte = bytes[source]
        buffer[target] = byte >= 'A'.ord && byte <= 'Z'.ord ? byte + 32 : byte
      end
      {finish - start, 0}
    end
  end

  private def self.ascii_whitespace?(byte : UInt8) : Bool
    byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
  end
end
