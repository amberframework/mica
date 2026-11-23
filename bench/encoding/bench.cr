# Throughput of Mica::Encoding against the platform's iconv, interleaved.
#
#   crystal-alpha build --release bench/encoding/bench.cr -o bench/bin/encoding_bench
#   bench/bin/encoding_bench [ROUNDS] [report.tsv]
#
# Build it with a compiler whose standard library uses iconv (stock Crystal,
# or crystal-alpha with -Duse_iconv once Mica is its default): the iconv
# side calls `Crystal::Iconv` directly with one converter reused across
# calls (the same work `IO::Decoder` does), and the per-call rows use
# `String.new(bytes, name)` / `String#encode`, which open a converter each
# time. Mica's side reuses one decoder or encoder (`convert` into a buffer)
# for the streaming rows and calls `Mica::Encoding.decode` / `.encode` for
# the per-call rows.
#
# Each case runs A (iconv) then B (Mica) for ROUNDS rounds (default 10);
# each run repeats the conversion for at least 40 ms. The report gives the
# median MB/s of each side and the ratio as "N× as fast" or "N× slower".
require "../../src/mica/encoding"
require "crystal/iconv"

alias Codec = Mica::Encoding::Codec

# Text for each encoding: ASCII words mixed with characters the encoding
# can represent, in the proportion typical of its script.
def corpus(codec : Codec, size : Int32) : String
  random = Random::PCG32.new(42)
  pool = case codec
         when .windows1252?, .iso8859_1?         then ("àéîõüçñßÄÖÜ€".chars)
         when .windows1251?, .koi8_r?            then ("абвгдежзийклмнопрстуфхцчшщыэюя".chars)
         when .shift_jis?, .eucjp?, .iso2022_jp? then ("日本語の文字列とひらがなカタカナを含む文章です".chars)
         when .gb18030?, .gbk?                   then ("中文字符串包含常用汉字和标点符号的句子".chars)
         when .big5?                             then ("中文字串包含常用漢字和標點符號的句子".chars)
         when .euckr?                            then ("한국어문자열과한글음절을포함하는문장입니다".chars)
         else                                         ("àéîõü日本語中文한국어😀€".chars)
         end
  ascii_share = codec.utf16_le? || codec.utf8? ? 80 : (codec.windows1252? || codec.windows1251? || codec.koi8_r? ? 85 : 40)
  String.build(size + 8) do |io|
    while io.bytesize < size
      if random.rand(100) < ascii_share
        io << "the quick brown fox jumps over"[random.rand(30)]
      else
        io << pool.sample(random)
      end
    end
  end
end

def measure(& : -> Int32) : Float64
  bytes = 0_i64
  started = Time.instant
  loop do
    bytes += yield
    elapsed = Time.instant - started
    return bytes / elapsed.total_seconds / 1_000_000.0 if elapsed.total_milliseconds >= 40
  end
end

def median(values : Array(Float64)) : Float64
  sorted = values.sort
  sorted[sorted.size // 2]
end

def ratio(mica : Float64, iconv : Float64) : String
  mica >= iconv ? "#{(mica / iconv).round(2)}× as fast" : "#{(iconv / mica).round(2)}× slower"
end

record Case, label : String, name : String, decode : Bool, size : Int32, per_call : Bool

rounds = (ARGV[0]? || "10").to_i
report = ARGV[1]?

names = [{"UTF-16LE", true}, {"WINDOWS-1252", true}, {"UTF-8", true}, {"UTF-16LE", false}, {"WINDOWS-1252", false},
         {"SHIFT_JIS", true}, {"SHIFT_JIS", false}, {"EUC-JP", true}, {"EUC-JP", false}, {"GB18030", true}, {"GB18030", false},
         {"BIG5", true}, {"BIG5", false}, {"EUC-KR", true}, {"EUC-KR", false}, {"ISO-2022-JP", true}, {"ISO-2022-JP", false},
         {"KOI8-R", true}]
cases = [] of Case
names.each do |name, decode|
  {64, 1024, 1024 * 1024}.each do |size|
    cases << Case.new("#{decode ? "decode" : "encode"} #{name} #{size}", name, decode, size, false)
  end
end
{"UTF-16LE", "WINDOWS-1252", "SHIFT_JIS"}.each do |name|
  cases << Case.new("String#encode #{name} 100 B per call", name, false, 100, true)
  cases << Case.new("String.new(bytes, #{name}) 100 B per call", name, true, 100, true)
end

rows = [] of String
puts "host #{System.hostname}, #{rounds} rounds ABAB, median MB/s of input"
cases.each do |entry|
  codec = Mica::Encoding.lookup!(entry.name, Mica::Encoding::LabelRule::IconvCompatible)
  text = corpus(codec, entry.size)
  utf8 = text.to_slice
  encoded = Mica::Encoding.encode(text, codec)
  input = entry.decode ? encoded : utf8
  output = Bytes.new(input.size * 4 + 64)
  iconv = entry.decode ? Crystal::Iconv.new(entry.name, "UTF-8") : Crystal::Iconv.new("UTF-8", entry.name)
  decoder = codec.decoder(Mica::Encoding::ErrorMode::Fatal)
  encoder = codec.encoder(Mica::Encoding::ErrorMode::Fatal)
  # Both sides must produce the same bytes before anything is timed.
  check = entry.decode ? Mica::Encoding.decode(input, codec, Mica::Encoding::ErrorMode::Fatal).to_slice : encoded
  iconv_check = entry.decode ? String.new(input, entry.name).to_slice : text.encode(entry.name)
  unless check == iconv_check
    puts "#{entry.label}\tnot timed: iconv and Mica write different bytes for this text"
    next
  end

  iconv_run = -> do
    if entry.per_call
      entry.decode ? String.new(input, entry.name).bytesize : text.encode(entry.name).size
    else
      inbuf = input.to_unsafe
      inleft = LibC::SizeT.new(input.size)
      outbuf = output.to_unsafe
      outleft = LibC::SizeT.new(output.size)
      iconv.convert(pointerof(inbuf), pointerof(inleft), pointerof(outbuf), pointerof(outleft))
      iconv.convert(Pointer(UInt8*).null, Pointer(LibC::SizeT).null, pointerof(outbuf), pointerof(outleft))
    end
    input.size
  end
  mica_run = -> do
    if entry.per_call
      entry.decode ? Mica::Encoding.decode(input, codec, Mica::Encoding::ErrorMode::Fatal).bytesize : Mica::Encoding.encode(text, codec).size
    else
      (entry.decode ? decoder : encoder).convert(input, output, last: true)
    end
    input.size
  end
  iconv_rates = [] of Float64
  mica_rates = [] of Float64
  rounds.times do
    iconv_rates << measure { iconv_run.call }
    mica_rates << measure { mica_run.call }
  end
  iconv.close
  iconv_median = median(iconv_rates)
  mica_median = median(mica_rates)
  line = "#{entry.label}\t#{iconv_median.round(1)}\t#{mica_median.round(1)}\t#{ratio(mica_median, iconv_median)}"
  puts line
  rows << line
end
if report
  File.write(report, "case\ticonv MB/s\tmica MB/s\tmica vs iconv\n" + rows.join('\n') + '\n')
end
