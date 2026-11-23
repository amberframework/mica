# Differential of Mica::Encoding (iconv-compatible names) against the
# platform's iconv through the standard library (`String.new(bytes, name)`
# and `String#encode`). Build it with a compiler whose standard library
# uses iconv (any stock Crystal, or crystal-alpha with -Duse_libiconv once
# Mica is its default).
#
#   crystal-alpha build --release conformance/encoding/iconv_differential.cr -o bin/iconv_differential
#   bin/iconv_differential SEED CASES_PER_ENCODING [report.tsv]
#
# Every case is compared in two modes: fatal (both must fail, or both must
# give the same output) and skip. A divergent input is shrunk to the
# shortest run of bytes (or characters) that still diverges, and
# divergences are grouped by that run, so the report lists each distinct
# behavior once with a count and an example. The groups are explained in
# docs/encoding.md ("Differences from iconv").
require "../../src/mica/encoding"

NAMES = %w(UTF-8 UTF-16LE UTF-16BE UTF-16 UTF-32LE UTF-32BE UTF-32 UCS-2LE UCS-2BE UCS-2 ASCII ISO-8859-1
  ISO-8859-2 ISO-8859-5 ISO-8859-7 ISO-8859-15 WINDOWS-1250 WINDOWS-1251 WINDOWS-1252 WINDOWS-1253 WINDOWS-1255
  WINDOWS-1256 KOI8-R KOI8-U MACINTOSH IBM866 SHIFT_JIS EUC-JP ISO-2022-JP EUC-KR GBK GB18030 BIG5 BIG5-HKSCS)

struct Outcome
  getter text : String?
  getter skipped : String

  def initialize(@text : String?, @skipped : String)
  end

  def ==(other : Outcome) : Bool
    text == other.text && skipped == other.skipped
  end
end

def iconv_decode(bytes : Bytes, name : String) : Outcome
  text = begin
    String.new(bytes, name)
  rescue ArgumentError
    nil
  end
  skipped = begin
    String.new(bytes, name, invalid: :skip)
  rescue ArgumentError
    "<error>"
  end
  Outcome.new(text, skipped)
end

def mica_decode(bytes : Bytes, codec : Mica::Encoding::Codec) : Outcome
  text = begin
    Mica::Encoding.decode(bytes, codec, Mica::Encoding::ErrorMode::Fatal)
  rescue Mica::Encoding::ConversionError
    nil
  end
  Outcome.new(text, Mica::Encoding.decode(bytes, codec, Mica::Encoding::ErrorMode::Skip))
end

def iconv_encode(text : String, name : String) : String
  text.encode(name).hexstring
rescue ArgumentError
  "<error>"
end

def mica_encode(text : String, codec : Mica::Encoding::Codec) : String
  Mica::Encoding.encode(text, codec).hexstring
rescue Mica::Encoding::ConversionError
  "<error>"
end

def random_bytes(random : Random) : Bytes
  Bytes.new(random.rand(1..24)) do
    case random.rand(10)
    when 0..2 then random.rand(0x20_u8..0x7E_u8)
    when 3    then {0x00_u8, 0x1B_u8, 0x24_u8, 0x28_u8, 0x42_u8, 0x0E_u8, 0x8E_u8, 0x8F_u8, 0xA1_u8, 0xFE_u8, 0xFF_u8, 0xD8_u8, 0xDC_u8}.sample(random)
    else           random.rand(0x80_u8..0xFF_u8)
    end
  end
end

def random_text(random : Random, codec : Mica::Encoding::Codec) : String
  String.build do |io|
    random.rand(1..12).times do
      code_point = case random.rand(8)
                   when 0..2 then random.rand(0x20..0x7E)
                   when 3    then random.rand(0xA0..0x52F)
                   when 4    then random.rand(0x2000..0x33FF)
                   when 5    then random.rand(0x4E00..0x9FFF)
                   when 6    then random.rand(0xAC00..0xFFEF)
                   else           random.rand(0x10000..0x2FFFF)
                   end
      io << code_point.chr unless 0xD800 <= code_point <= 0xDFFF
    end
  end
end

# Shrinks a divergent byte string to its shortest divergent window.
def shrink(bytes : Bytes, & : Bytes -> Bool) : Bytes
  (1..bytes.size).each do |length|
    (0..bytes.size - length).each do |start|
      window = bytes[start, length]
      return window if yield window
    end
  end
  bytes
end

seed = (ARGV[0]? || abort("usage: iconv_differential SEED CASES [report.tsv]")).to_u64
cases = (ARGV[1]? || abort("usage: iconv_differential SEED CASES [report.tsv]")).to_i
report = ARGV[2]?

groups = Hash({String, String, String}, {Int32, String}).new
total_divergent = 0
unsupported = [] of String
NAMES.each do |name|
  codec = Mica::Encoding.lookup!(name, Mica::Encoding::LabelRule::IconvCompatible)
  begin
    String.new(Bytes[0x41], name)
  rescue ArgumentError
    unsupported << name
    next
  end
  random = Random::PCG32.new(seed, name.hash)
  divergent = 0
  cases.times do
    bytes = random_bytes(random)
    next if iconv_decode(bytes, name) == mica_decode(bytes, codec)
    divergent += 1
    window = shrink(bytes) { |candidate| iconv_decode(candidate, name) != mica_decode(candidate, codec) }
    expected = iconv_decode(window, name)
    actual = mica_decode(window, codec)
    key = {name, "decode", window.hexstring}
    count, _ = groups[key]? || {0, ""}
    groups[key] = {count + 1, "iconv #{expected.text.inspect}/#{expected.skipped.inspect} mica #{actual.text.inspect}/#{actual.skipped.inspect}"}
  end
  encode_divergent = 0
  (cases // 4).times do
    text = random_text(random, codec)
    next if iconv_encode(text, name) == mica_encode(text, codec)
    encode_divergent += 1
    first = text.chars.find { |char| iconv_encode(char.to_s, name) != mica_encode(char.to_s, codec) }
    key = {name, "encode", first ? "U+%04X" % first.ord : "context:#{text.inspect}"}
    count, _ = groups[key]? || {0, ""}
    sample = first ? first.to_s : text
    groups[key] = {count + 1, "iconv #{iconv_encode(sample, name)} mica #{mica_encode(sample, codec)}"}
  end
  total_divergent += divergent + encode_divergent
  puts "#{name.ljust(12)} decode #{divergent} / #{cases} diverge, encode #{encode_divergent} / #{cases // 4} diverge"
end
puts "not supported by this iconv: #{unsupported.join(", ")}" unless unsupported.empty?
by_encoding = groups.keys.group_by { |key| {key[0], key[1]} }
puts "seed=#{seed} cases=#{cases} divergent=#{total_divergent} distinct_groups=#{groups.size}"
by_encoding.each do |(name, direction), keys|
  puts "  #{name} #{direction}: #{keys.size} groups, e.g. #{keys.first(3).map { |key| "#{key[2]} (#{groups[key][1]})" }.join("; ")}"
end
if report
  File.open(report, "w") do |file|
    file << "encoding\tdirection\tminimal input\tcount\tbehavior\n"
    groups.to_a.sort_by! { |key, _| key }.each do |key, value|
      file << key[0] << '\t' << key[1] << '\t' << key[2] << '\t' << value[0] << '\t' << value[1] << '\n'
    end
  end
end
