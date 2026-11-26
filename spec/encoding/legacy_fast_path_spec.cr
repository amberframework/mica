require "./support"

private alias Codec = Mica::Encoding::Codec
private alias ErrorMode = Mica::Encoding::ErrorMode
private alias Result = Mica::Encoding::Result

private SEED   = ENV["MICA_ENCODING_SEED"]?.try(&.to_u64) || 20261126_u64
private ROUNDS = ENV["MICA_ENCODING_ROUNDS"]?.try(&.to_i) || 400

# Each legacy decoder with its fast path switched off, so every byte goes
# through `step` whatever the chunking.
{% for name in %w(GB18030Decoder Big5Decoder EUCJPDecoder ISO2022JPDecoder ShiftJISDecoder EUCKRDecoder ReplacementDecoder) %}
  private class StepOnly{{ name.id }} < Mica::Encoding::{{ name.id }}
    private def fast_path? : Bool
      false
    end
  end
{% end %}

private CODECS = [Codec::ShiftJIS, Codec::EUCJP, Codec::GB18030, Codec::GBK, Codec::Big5, Codec::Big5HKSCS,
                  Codec::EUCKR, Codec::ISO2022JP, Codec::Replacement]

private def step_only_decoder(codec : Codec, mode : ErrorMode) : Mica::Encoding::Decoder
  case codec
  when .gbk?, .gb18030?     then StepOnlyGB18030Decoder.new(codec, mode)
  when .big5?, .big5_hkscs? then StepOnlyBig5Decoder.new(codec, mode)
  when .eucjp?              then StepOnlyEUCJPDecoder.new(codec, mode)
  when .iso2022_jp?         then StepOnlyISO2022JPDecoder.new(codec, mode)
  when .shift_jis?          then StepOnlyShiftJISDecoder.new(codec, mode)
  when .euckr?              then StepOnlyEUCKRDecoder.new(codec, mode)
  when .replacement?        then StepOnlyReplacementDecoder.new(codec, mode)
  else
    raise ArgumentError.new("#{codec} has no legacy decoder")
  end
end

# The lead and trail byte ranges a codec's two-byte characters use.
private def pair_ranges(codec : Codec) : {Array(Range(Int32, Int32)), Array(Range(Int32, Int32))}
  case codec
  when .shift_jis?
    {[0x81..0x9F, 0xE0..0xFC], [0x40..0x7E, 0x80..0xFC]}
  when .eucjp?
    {[0xA1..0xFE], [0xA1..0xFE]}
  when .gbk?, .gb18030?
    {[0x81..0xFE], [0x40..0x7E, 0x80..0xFE]}
  when .big5?, .big5_hkscs?
    {[0x81..0xFE], [0x40..0x7E, 0xA1..0xFE]}
  when .euckr?
    {[0x81..0xFE], [0x41..0xFE]}
  else
    {[0x21..0x7E], [0x21..0x7E]}
  end
end

private def pick(random : Random, ranges : Array(Range(Int32, Int32))) : UInt8
  random.rand(ranges[random.rand(ranges.size)]).to_u8
end

# Bytes weighted toward a codec's real lead and trail ranges: ASCII runs
# long enough for the eight-byte path, two-byte characters, leads with a
# wrong trail, the bytes that open longer sequences, and random bytes.
private def random_legacy_bytes(codec : Codec, random : Random) : Bytes
  leads, trails = pair_ranges(codec)
  specials = Bytes[0x80, 0x8E, 0x8F, 0xA0, 0xFF, 0x1B, 0x0E, 0x30, 0x39, 0x24, 0x28, 0x42, 0x40, 0x7F]
  io = IO::Memory.new
  random.rand(0..(random.rand(4) == 0 ? 120 : 24)).times do
    case random.rand(20)
    when 0..4 # an ASCII run
      random.rand(1..(random.rand(8) == 0 ? 140 : 20)).times { io.write_byte(random.rand(0x20_u8..0x7E_u8)) }
    when 5..11 # a two-byte character
      io.write_byte(pick(random, leads))
      io.write_byte(pick(random, trails))
    when 12 # a lead and any byte
      io.write_byte(pick(random, leads))
      io.write_byte(random.rand(0x00_u8..0xFF_u8))
    when 13 # gb18030 four bytes, valid or near it
      io.write_byte(random.rand(0x81_u8..0xFE_u8))
      io.write_byte(random.rand(0x2F_u8..0x3A_u8))
      io.write_byte(random.rand(0x80_u8..0xFF_u8))
      io.write_byte(random.rand(0x2F_u8..0x3A_u8))
    when 14 # Big5's composed pairs and EUC-JP's 0x8E and 0x8F sequences
      io.write(Bytes[0x88, {0x62, 0x64, 0xA3, 0xA5, 0x63}.sample(random).to_u8])
      io.write_byte(0x8E_u8)
      io.write_byte(random.rand(0xA0_u8..0xE0_u8))
      io.write_byte(0x8F_u8)
      io.write_byte(pick(random, [0xA1..0xFE]))
      io.write_byte(pick(random, [0xA0..0xFF]))
    when 15 # an ISO-2022-JP escape
      io.write(Bytes[0x1B, {0x24, 0x28}.sample(random).to_u8, {0x40, 0x42, 0x4A, 0x49}.sample(random).to_u8])
    when 16
      io.write_byte(specials[random.rand(specials.size)])
    else
      io.write_byte(random.rand(0x00_u8..0xFF_u8))
    end
  end
  io.write_byte(pick(random, leads)) if random.rand(4) == 0 # a lead left open at the end
  io.to_slice
end

# Feeds *input* to *decoder* in the chunk sizes *chunk_size* returns, into
# an output buffer of *output_size* bytes, going on after fatal errors.
# Returns the output and every result.
private def drive(decoder : Mica::Encoding::Decoder, input : Bytes, output_size : Int32, & : Int32 -> Int32) : {Bytes, Array(Result)}
  output = IO::Memory.new
  buffer = Bytes.new(output_size)
  results = [] of Result
  offset = 0
  loop do
    remaining = input.size - offset
    chunk_size = remaining == 0 ? 0 : yield remaining
    last = offset + chunk_size == input.size
    chunk = input[offset, chunk_size]
    loop do
      result = decoder.convert(chunk, buffer, last)
      results << result
      output.write(buffer[0, result.written])
      chunk = chunk[result.read..]
      offset += result.read
      # After a fatal error, convert again: the rest of the chunk and any
      # restored bytes are still to come.
      break unless result.output_full? || result.error?
    end
    break if last
  end
  {output.to_slice, results}
end

private def problems(results : Array(Result)) : Array({Mica::Encoding::Problem?, Int64})
  results.select(&.error?).map { |result| {result.problem, result.offset} }
end

describe "Mica::Encoding legacy decoder fast path" do
  it_satisfies "ENC-STREAMING", "decodes each call the same as the byte-by-byte path, with the same chunks and output buffer (seed #{SEED})" do
    random = Random::PCG32.new(SEED)
    cases = 0
    CODECS.each do |codec|
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          input = random_legacy_bytes(codec, random)
          sizes = Array(Int32).new(input.size + 1) { random.rand(1..Math.max(1, input.size)) }
          output_size = random.rand(2) == 0 ? Mica::Encoding::MIN_OUTPUT_BYTES : random.rand(Mica::Encoding::MIN_OUTPUT_BYTES..input.size * 3 + 200)
          index = -1
          fast_output, fast_results = drive(codec.decoder(mode), input, output_size) { |remaining| Math.min(sizes[index += 1], remaining) }
          index = -1
          step_output, step_results = drive(step_only_decoder(codec, mode), input, output_size) { |remaining| Math.min(sizes[index += 1], remaining) }
          unless fast_output == step_output && fast_results == step_results
            fail "#{codec} #{mode} #{input.hexstring}:\n fast #{fast_output.hexstring} #{fast_results.inspect}\n step #{step_output.hexstring} #{step_results.inspect}"
          end
          cases += 1
        end
      end
    end
    cases.should eq(CODECS.size * ErrorMode.values.size * ROUNDS)
  end

  it_satisfies "ENC-STREAMING", "decodes random chunks the same as one byte per call, which never sees a trail byte in the same chunk (seed #{SEED})" do
    random = Random::PCG32.new(SEED + 1)
    CODECS.each do |codec|
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          input = random_legacy_bytes(codec, random)
          fast_output, fast_results = drive(codec.decoder(mode), input, Mica::Encoding::MIN_OUTPUT_BYTES) { |remaining| random.rand(1..remaining) }
          byte_output, byte_results = drive(codec.decoder(mode), input, Mica::Encoding::MIN_OUTPUT_BYTES) { 1 }
          fast_statuses = fast_results.map(&.status).uniq!.sort
          byte_statuses = byte_results.map(&.status).uniq!.sort
          unless fast_output == byte_output && problems(fast_results) == problems(byte_results) &&
                 fast_statuses.includes?(Mica::Encoding::Status::Error) == byte_statuses.includes?(Mica::Encoding::Status::Error)
            fail "#{codec} #{mode} #{input.hexstring}:\n fast #{fast_output.hexstring} #{problems(fast_results)}\n byte #{byte_output.hexstring} #{problems(byte_results)}"
          end
        end
      end
    end
  end

  it_satisfies "ENC-CJK", "decodes long mixed text the same through the fast path and one byte per call" do
    {Codec::ShiftJIS, Codec::EUCJP, Codec::GB18030, Codec::GBK, Codec::Big5, Codec::Big5HKSCS, Codec::EUCKR, Codec::ISO2022JP}.each do |codec|
      text = "the quick brown fox 日本語の文字列 中文字符串 한국어 jumps over" * 40
      encoded = Mica::Encoding.encode(text.gsub(/[^\x00-\x7F]/) { |char| codec_can_encode?(codec, char) ? char : "?" }, codec)
      byte_output, _ = drive(codec.decoder(ErrorMode::Fatal), encoded, Mica::Encoding::MIN_OUTPUT_BYTES) { 1 }
      String.new(byte_output).should eq(Mica::Encoding.decode(encoded, codec, ErrorMode::Fatal))
      Mica::Encoding.encode(Mica::Encoding.decode(encoded, codec, ErrorMode::Fatal), codec).should eq(encoded)
    end
  end

  it_satisfies "ENC-CJK", "forgets an EUC-JP JIS X 0212 lead when the input ends inside it" do
    ErrorMode.values.each do |mode|
      decoder = Codec::EUCJP.decoder(mode)
      buffer = Bytes.new(Mica::Encoding::MIN_OUTPUT_BYTES)
      first = decoder.convert(Bytes[0x8F, 0xA2], buffer, last: true)
      first.problem.should eq(Mica::Encoding::Problem::IncompleteSequence) if mode.fatal?
      result = decoder.convert(Bytes[0xB0, 0xA1], buffer, last: true)
      String.new(buffer[0, result.written]).should eq("亜")
      step_only = step_only_decoder(Codec::EUCJP, mode)
      step_only.convert(Bytes[0x8F, 0xA2], buffer, last: true)
      result = step_only.convert(Bytes[0xB0], buffer, last: false)
      result = step_only.convert(Bytes[0xA1], buffer, last: true)
      String.new(buffer[0, result.written]).should eq("亜")
    end
  end
end

private def codec_can_encode?(codec : Codec, char : String) : Bool
  Mica::Encoding.encode(char, codec, ErrorMode::Fatal)
  true
rescue Mica::Encoding::ConversionError
  false
end
