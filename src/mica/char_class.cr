module Mica
  # :nodoc:
  #
  # Character classification for the scanner. ASCII bytes are classified
  # through one compile-time lookup table; non-ASCII code points go through
  # the XML 1.0 (5th edition) range checks.
  module CharClass
    NAME_START   = 0x01_u8
    NAME_CHAR    = 0x02_u8
    TEXT_STOP    = 0x04_u8
    ATTR_STOP    = 0x08_u8
    SPACE        = 0x10_u8
    CONTENT_STOP = 0x20_u8

    # One flag byte per byte value. Built at compile time so the hot loops
    # read a StaticArray constant with no lazy-initialization check.
    {% begin %}
    TABLE = StaticArray[
      {% for b in 0..255 %}
        {%
          flags = 0
          # NameStartChar (ASCII part): ":" | [A-Z] | "_" | [a-z]
          if b == 58 || (b >= 65 && b <= 90) || b == 95 || (b >= 97 && b <= 122)
            flags = flags | 1 | 2
          end
          # NameChar adds "-" | "." | [0-9]
          if b == 45 || b == 46 || (b >= 48 && b <= 57)
            flags = flags | 2
          end
          # Text stops at markup, references, line ends, "]" (for "]]>"),
          # control characters and every non-ASCII lead byte.
          if b == 60 || b == 38 || b == 13 || b == 10 || b == 93 || (b < 32 && b != 9) || b >= 128
            flags = flags | 4
          end
          # Attribute values stop at markup, references, quotes, whitespace
          # that needs normalization, control characters and non-ASCII bytes.
          if b == 60 || b == 38 || b == 34 || b == 39 || b == 9 || b == 10 || b == 13 || b < 32 || b >= 128
            flags = flags | 8
          end
          if b == 32 || b == 9 || b == 10 || b == 13
            flags = flags | 16
          end
          # Generic content scanning (comments, PIs, CDATA) stops at line
          # ends, control characters and non-ASCII bytes plus the
          # terminator candidates "-", "?" and "]".
          if b == 13 || b == 10 || (b < 32 && b != 9) || b >= 128 || b == 45 || b == 63 || b == 93
            flags = flags | 32
          end
        %}
        {{ flags }}_u8,
      {% end %}
    ]
    {% end %}

    @[AlwaysInline]
    def self.flags(byte : UInt8) : UInt8
      TABLE.unsafe_fetch(byte)
    end

    @[AlwaysInline]
    def self.space?(byte : UInt8) : Bool
      byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    end

    # Returns true if *code* matches the XML 1.0 `Char` production.
    def self.xml_char?(code : Int32) : Bool
      if code < 0x20
        code == 0x09 || code == 0x0A || code == 0x0D
      elsif code <= 0xD7FF
        true
      elsif code < 0xE000
        false
      elsif code <= 0xFFFD
        true
      else
        code >= 0x10000 && code <= 0x10FFFF
      end
    end

    # Returns true if *code* matches `NameStartChar`.
    def self.name_start_char?(code : Int32) : Bool
      if code < 0x80
        TABLE.unsafe_fetch(code) & NAME_START != 0
      else
        (code >= 0xC0 && code <= 0xD6) ||
          (code >= 0xD8 && code <= 0xF6) ||
          (code >= 0xF8 && code <= 0x2FF) ||
          (code >= 0x370 && code <= 0x37D) ||
          (code >= 0x37F && code <= 0x1FFF) ||
          (code >= 0x200C && code <= 0x200D) ||
          (code >= 0x2070 && code <= 0x218F) ||
          (code >= 0x2C00 && code <= 0x2FEF) ||
          (code >= 0x3001 && code <= 0xD7FF) ||
          (code >= 0xF900 && code <= 0xFDCF) ||
          (code >= 0xFDF0 && code <= 0xFFFD) ||
          (code >= 0x10000 && code <= 0xEFFFF)
      end
    end

    # Returns true if *code* matches `NameChar`.
    def self.name_char?(code : Int32) : Bool
      if code < 0x80
        TABLE.unsafe_fetch(code) & NAME_CHAR != 0
      else
        name_start_char?(code) ||
          code == 0xB7 ||
          (code >= 0x300 && code <= 0x36F) ||
          (code >= 0x203F && code <= 0x2040)
      end
    end

    # Returns true if *code* matches `PubidChar`.
    def self.pubid_char?(code : Int32) : Bool
      return true if code == 0x20 || code == 0x0D || code == 0x0A
      return true if (code >= 'a'.ord && code <= 'z'.ord) || (code >= 'A'.ord && code <= 'Z'.ord) || (code >= '0'.ord && code <= '9'.ord)
      "-'()+,./:=?;!*#@$_%".includes?(code.chr)
    end

    # Decodes one UTF-8 sequence starting at *ptr* with *available* bytes.
    #
    # Returns `{code_point, byte_length}`; byte_length is 0 when more bytes
    # are needed and -1 when the sequence is invalid (overlong, surrogate,
    # out of range, or a bad continuation byte).
    def self.decode_utf8(ptr : UInt8*, available : Int32) : {Int32, Int32}
      b0 = ptr[0].to_i32
      if b0 < 0x80
        return {b0, 1}
      elsif b0 < 0xC2
        return {0, -1}
      elsif b0 < 0xE0
        return {0, 0} if available < 2
        b1 = ptr[1].to_i32
        return {0, -1} unless b1 & 0xC0 == 0x80
        return {((b0 & 0x1F) << 6) | (b1 & 0x3F), 2}
      elsif b0 < 0xF0
        return {0, 0} if available < 3
        b1 = ptr[1].to_i32
        b2 = ptr[2].to_i32
        return {0, -1} unless b1 & 0xC0 == 0x80 && b2 & 0xC0 == 0x80
        code = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
        return {0, -1} if code < 0x800 || (code >= 0xD800 && code <= 0xDFFF)
        return {code, 3}
      elsif b0 < 0xF5
        return {0, 0} if available < 4
        b1 = ptr[1].to_i32
        b2 = ptr[2].to_i32
        b3 = ptr[3].to_i32
        return {0, -1} unless b1 & 0xC0 == 0x80 && b2 & 0xC0 == 0x80 && b3 & 0xC0 == 0x80
        code = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
        return {0, -1} if code < 0x10000 || code > 0x10FFFF
        return {code, 4}
      else
        return {0, -1}
      end
    end

    # Returns the number of bytes the UTF-8 sequence starting with *lead* has
    # (1 for ASCII and for invalid lead bytes).
    def self.utf8_sequence_length(lead : UInt8) : Int32
      if lead < 0xC0
        1
      elsif lead < 0xE0
        2
      elsif lead < 0xF0
        3
      else
        4
      end
    end
  end
end
