require "./tables/labels"
require "./tables/single_byte"
require "./tables/jis0208"
require "./tables/jis0212"
require "./tables/iso_2022_jp_katakana"
require "./tables/euc_kr"
require "./tables/gb18030"
require "./tables/big5"

# Lookups over the generated index tables (scripts/generate_encoding_tables.rb).
# Every table is a read-only `Slice.literal`; nothing here allocates.
module Mica::Encoding::Tables
  # Returns the index code point for *pointer* in *index*, or -1 when the
  # pointer has none.
  @[AlwaysInline]
  def self.code_point(index : Slice, pointer : Int32) : Int32
    return -1 if pointer < 0 || pointer >= index.size
    code_point = index.unsafe_fetch(pointer).to_i32
    code_point == 0 ? -1 : code_point
  end

  # Returns the value a reverse table holds for *code_point* (a pointer, or
  # for the single-byte tables the byte minus 0x80), or -1 when it holds
  # none. A reverse table is four slices: a page map for the Basic
  # Multilingual Plane (one entry per high byte: 0, or the 1-based number
  # of a 256-entry block in *values*, whose entries are value + 1), and a
  # sorted list of code points above U+FFFF with their values.
  @[AlwaysInline]
  def self.reverse(code_point : Int32, pages : Slice(UInt16), values : Slice(T), astral_code_points : Slice(UInt32), astral_values : Slice(T)) : Int32 forall T
    if code_point <= 0xFFFF
      page = pages.unsafe_fetch(code_point >> 8).to_i32
      return -1 if page == 0
      values.unsafe_fetch(((page - 1) << 8) | (code_point & 0xFF)).to_i32 - 1
    else
      found = astral_code_points.bsearch_index { |candidate| candidate >= code_point.to_u32 }
      return -1 unless found && astral_code_points.unsafe_fetch(found) == code_point.to_u32
      astral_values.unsafe_fetch(found).to_i32
    end
  end

  {% for name in %w(JIS0208_ENCODE SHIFT_JIS_ENCODE EUC_KR_ENCODE GB18030_ENCODE BIG5_ENCODE BIG5_HKSCS_ENCODE) %}
    # Returns the pointer for *code_point* in this reverse table, or -1.
    def self.{{ name.downcase.id }}(code_point : Int32) : Int32
      reverse(code_point, {{ name.id }}_PAGES, {{ name.id }}_VALUES, {{ name.id }}_ASTRAL_CODE_POINTS, {{ name.id }}_ASTRAL_VALUES)
    end
  {% end %}

  # Returns the code point for a four-byte gb18030 *pointer* (the
  # Encoding Standard's "index gb18030 ranges code point"), or -1.
  def self.gb18030_ranges_code_point(pointer : Int32) : Int32
    return -1 if (pointer > 39419 && pointer < 189000) || pointer > 1237575
    return 0xE7C7 if pointer == 7457
    found = GB18030_RANGE_POINTERS.bsearch_index { |offset| offset > pointer.to_u32 } || GB18030_RANGE_POINTERS.size
    index = found - 1
    GB18030_RANGE_CODE_POINTS.unsafe_fetch(index).to_i32 + pointer - GB18030_RANGE_POINTERS.unsafe_fetch(index).to_i32
  end

  # Returns the four-byte gb18030 pointer for *code_point* (the Encoding
  # Standard's "index gb18030 ranges pointer").
  def self.gb18030_ranges_pointer(code_point : Int32) : Int32
    return 7457 if code_point == 0xE7C7
    found = GB18030_RANGE_CODE_POINTS.bsearch_index { |offset| offset > code_point.to_u32 } || GB18030_RANGE_CODE_POINTS.size
    index = found - 1
    GB18030_RANGE_POINTERS.unsafe_fetch(index).to_i32 + code_point - GB18030_RANGE_CODE_POINTS.unsafe_fetch(index).to_i32
  end

  # Index single-byte for a legacy single-byte *codec*: 128 code points
  # for bytes 0x80 to 0xFF, 0 for none.
  def self.single_byte(codec : Codec) : Slice(UInt16)
    {% begin %}
      case codec
      {% for member in %w(IBM866 ISO8859_2 ISO8859_3 ISO8859_4 ISO8859_5 ISO8859_6 ISO8859_7 ISO8859_8 ISO8859_10 ISO8859_13 ISO8859_14 ISO8859_15 ISO8859_16 KOI8_R KOI8_U Macintosh Windows874 Windows1250 Windows1251 Windows1252 Windows1253 Windows1254 Windows1255 Windows1256 Windows1257 Windows1258 XMacCyrillic) %}
        when Codec::{{ member.id }} then {{ member.upcase.id }}
      {% end %}
      when Codec::ISO8859_8_I    then ISO8859_8
      when Codec::ISO8859_1      then LATIN1
      when Codec::XUserDefined   then X_USER_DEFINED
      when Codec::USASCII        then ASCII_ONLY
      else
        raise ArgumentError.new("#{codec.name} is not a single-byte encoding")
      end
    {% end %}
  end

  # The reverse tables for a table-driven single-byte *codec*, or nil for
  # the ones encoded by arithmetic (exact ISO-8859-1, x-user-defined,
  # US-ASCII). Pass them to `reverse`; a value is the byte minus 0x80.
  def self.single_byte_encode_tables(codec : Codec) : {Slice(UInt16), Slice(UInt8), Slice(UInt32), Slice(UInt8)}?
    {% begin %}
      case codec
      {% for member in %w(IBM866 ISO8859_2 ISO8859_3 ISO8859_4 ISO8859_5 ISO8859_6 ISO8859_7 ISO8859_8 ISO8859_10 ISO8859_13 ISO8859_14 ISO8859_15 ISO8859_16 KOI8_R KOI8_U Macintosh Windows874 Windows1250 Windows1251 Windows1252 Windows1253 Windows1254 Windows1255 Windows1256 Windows1257 Windows1258 XMacCyrillic) %}
        when Codec::{{ member.id }}
          { {{ member.upcase.id }}_ENCODE_PAGES, {{ member.upcase.id }}_ENCODE_VALUES, {{ member.upcase.id }}_ENCODE_ASTRAL_CODE_POINTS, {{ member.upcase.id }}_ENCODE_ASTRAL_VALUES }
      {% end %}
      when Codec::ISO8859_8_I
        {ISO8859_8_ENCODE_PAGES, ISO8859_8_ENCODE_VALUES, ISO8859_8_ENCODE_ASTRAL_CODE_POINTS, ISO8859_8_ENCODE_ASTRAL_VALUES}
      else
        nil
      end
    {% end %}
  end

  # Exact ISO-8859-1: byte n is U+00nn.
  LATIN1 = Slice(UInt16).new(128) { |offset| (0x80 + offset).to_u16 }

  # x-user-defined: bytes 0x80 to 0xFF are U+F780 to U+F7FF.
  X_USER_DEFINED = Slice(UInt16).new(128) { |offset| (0xF780 + offset).to_u16 }

  # US-ASCII: no byte above 0x7F has a code point.
  ASCII_ONLY = Slice(UInt16).new(128, 0_u16)
end
