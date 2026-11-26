require "./support"

private alias Codec = Mica::Encoding::Codec
private alias ErrorMode = Mica::Encoding::ErrorMode
private alias Encoder = Mica::Encoding::Encoder

private SEED   = ENV["MICA_ENCODING_SEED"]?.try(&.to_u64) || 20261126_u64
private ROUNDS = ENV["MICA_ENCODING_ROUNDS"]?.try(&.to_i) || 40

# Bytes after the output buffer that no call may touch.
private CANARY_BYTES =      32
private CANARY       = 0xA5_u8

# Everything a run of `convert` calls reports: the output, every problem
# (with the converter's position after it) and the position at the end.
private record Trace,
  output : Bytes,
  list_of_problems : Array({Mica::Encoding::Problem?, Int64, Int32, Int64}),
  final_status : Mica::Encoding::Status,
  position : Int64

# Every codec with an encoder, minus the UTF-16 and UCS-2 family (their
# encoder is tuned and tested separately).
private def list_of_fast_path_codecs : Array(Codec)
  Codec.values.reject do |codec|
    codec.replacement? || codec.utf16? || codec.utf16_be? || codec.utf16_le? || codec.ucs2? || codec.ucs2_be? || codec.ucs2_le?
  end
end

# Whether every ASCII byte is a one-byte step of its own for *codec*
# (ISO-2022-JP may write an escape first, UTF-32 four bytes, BIG5-HKSCS a
# held letter).
private def writes_ascii_as_one_step?(codec : Codec) : Bool
  !(codec.iso2022_jp? || codec.utf32? || codec.utf32_be? || codec.utf32_le? || codec.big5_hkscs?)
end

# Characters *codec* can write: what its decoder makes of random bytes.
private def mappable_characters(codec : Codec, random : Random) : Array(Char)
  return [] of Char if codec.utf8? || codec.utf32? || codec.utf32_be? || codec.utf32_le?
  bytes = Bytes.new(8192) { random.rand(0x80..0xFF).to_u8 }
  decoded = Mica::Encoding.decode(bytes, codec, ErrorMode::Replacement)
  decoded.chars.reject { |char| char.ord < 0x80 || char == '�' }.uniq
end

# UTF-8 bytes mixing ASCII runs, *pool* characters, characters the
# encoding lacks, astral code points, and ill-formed and cut-off sequences.
private def random_fast_path_input(random : Random, pool : Array(Char)) : Bytes
  io = IO::Memory.new
  random.rand(0..48).times do
    case random.rand(16)
    when 0..3
      random.rand(1..20).times { io << random.rand(0x20..0x7E).chr }
    when 4..7
      io << (pool.empty? ? random.rand(0x4E00..0x9FFF).chr : pool.sample(random))
    when 8
      io << random.rand(0x00..0x1F).chr
    when 9
      io << {0xA5, 0x203E, 0x2212, 0xFF61, 0xFF9F, 0x20AC, 0xE5E5, 0xE78D, 0xE864, 0xCA, 0xEA, 0x304, 0x30C, 0xFEFF, 0x80, 0xFF, 0xF780}.sample(random).chr
    when 10
      code_point = random.rand(0x80..0xFFFF)
      code_point = 0x4E00 if code_point >= 0xD800 && code_point <= 0xDFFF
      io << code_point.chr
    when 11
      io << random.rand(0x10000..0x10FFFF).chr
    when 12
      io.write_byte(random.rand(0x80..0xFF).to_u8)
    when 13
      # A sequence cut short.
      encoded = {random.rand(0x800..0xD7FF), random.rand(0xE000..0xFFFF), random.rand(0x10000..0x10FFFF)}.sample(random).chr.to_s.to_slice
      io.write(encoded[0, random.rand(1...encoded.size)])
    when 14
      io.write({Bytes[0xC0, 0x80], Bytes[0xC1, 0xBF], Bytes[0xE0, 0x80, 0x80], Bytes[0xED, 0xA0, 0x80], Bytes[0xF0, 0x80, 0x80, 0x80],
                Bytes[0xF4, 0x90, 0x80, 0x80], Bytes[0xF5, 0x80], Bytes[0xFF], Bytes[0xE3, 0x41], Bytes[0xF0, 0x9F, 0x98]}.sample(random))
    else
      io << random.rand(0xAC00..0xD7A3).chr
    end
  end
  io.to_slice
end

# Feeds *input* to *encoder* in the chunk sizes *chunk_sizes* yields, into
# an output buffer of *output_size* bytes followed by canary bytes, going
# on after each fatal error as a caller may.
private def trace_encoder(encoder : Encoder, input : Bytes, output_size : Int32, & : Int32 -> Int32) : Trace
  memory = Bytes.new(output_size + CANARY_BYTES, CANARY)
  buffer = memory[0, output_size]
  output = IO::Memory.new
  list_of_problems = [] of {Mica::Encoding::Problem?, Int64, Int32, Int64}
  offset = 0
  final_status = Mica::Encoding::Status::InputEmpty
  loop do
    remaining = input.size - offset
    chunk_size = remaining == 0 ? 0 : (yield remaining).clamp(1, remaining)
    last = offset + chunk_size == input.size
    chunk = input[offset, chunk_size]
    loop do
      result = encoder.convert(chunk, buffer, last)
      unless memory[output_size, CANARY_BYTES].all?(CANARY)
        raise "#{encoder.codec} wrote past the output buffer"
      end
      if result.output_full? && result.written <= output_size - Mica::Encoding::MIN_OUTPUT_BYTES
        raise "#{encoder.codec} returned OutputFull with room left"
      end
      # A step that was one ASCII byte wrote one byte, so the call stops
      # the moment the output passes the limit, not a byte later.
      if result.output_full? && result.read > 0 && chunk[result.read - 1] < 0x80 && writes_ascii_as_one_step?(encoder.codec) &&
         result.written != output_size - Mica::Encoding::MIN_OUTPUT_BYTES + 1
        raise "#{encoder.codec} passed the output limit by more than one ASCII byte"
      end
      if !result.output_full? && !result.error? && result.read != chunk.size
        raise "#{encoder.codec} returned #{result.status} without reading its input"
      end
      output.write(buffer[0, result.written])
      chunk = chunk[result.read..]
      offset += result.read
      final_status = result.status
      list_of_problems << {result.problem, result.offset, result.code_point, encoder.position} if result.error?
      break unless result.output_full? || result.error?
    end
    break if last
  end
  Trace.new(output.to_slice.dup, list_of_problems, final_status, encoder.position)
end

describe "Mica::Encoding encoder fast path" do
  it_satisfies "ENC-STREAMING", "encodes whole-chunk input exactly as one byte per call does, in every encoder and error mode (seed #{SEED})" do
    random = Random::PCG32.new(SEED)
    cases = 0
    list_of_fast_path_codecs.each do |codec|
      pool = mappable_characters(codec, random)
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          input = random_fast_path_input(random, pool)
          expected = trace_encoder(codec.encoder(mode), input, Mica::Encoding::MIN_OUTPUT_BYTES) { 1 }
          {
            ->(remaining : Int32) { remaining },
            ->(remaining : Int32) { random.rand(1..remaining) },
            ->(remaining : Int32) { random.rand(1..8) },
          }.each_with_index do |chunking, style|
            output_size = style == 0 ? input.size * 13 + 64 : Mica::Encoding::MIN_OUTPUT_BYTES
            actual = trace_encoder(codec.encoder(mode), input, output_size) { |remaining| chunking.call(remaining) }
            unless actual == expected
              fail "#{codec} #{mode} chunking #{style} input #{input.hexstring}:\n  byte by byte #{expected.inspect}\n  chunked      #{actual.inspect}"
            end
            actual = trace_encoder(codec.encoder(mode), input, Mica::Encoding::MIN_OUTPUT_BYTES) { |remaining| chunking.call(remaining) }
            unless actual == expected
              fail "#{codec} #{mode} chunking #{style} (16-byte output) input #{input.hexstring}:\n  byte by byte #{expected.inspect}\n  chunked      #{actual.inspect}"
            end
          end
          cases += 1
        end
      end
    end
    cases.should eq(list_of_fast_path_codecs.size * ErrorMode.values.size * ROUNDS)
  end

  it_satisfies "ENC-STREAMING", "copies long ASCII runs word by word up to the output limit, as one byte per call does" do
    random = Random::PCG32.new(SEED &+ 1)
    list_of_fast_path_codecs.each do |codec|
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          text = String.build do |io|
            random.rand(1..200).times { io << random.rand(0x20..0x7E).chr }
            io << "中" if random.rand(2) == 0
            random.rand(0..40).times { io << random.rand(0x20..0x7E).chr }
          end
          input = text.to_slice
          expected = trace_encoder(codec.encoder(mode), input, Mica::Encoding::MIN_OUTPUT_BYTES) { 1 }
          output_size = random.rand(Mica::Encoding::MIN_OUTPUT_BYTES..Mica::Encoding::MIN_OUTPUT_BYTES + 24)
          actual = trace_encoder(codec.encoder(mode), input, output_size) { |remaining| remaining }
          actual.should eq(expected)
        end
      end
    end
  end
end
