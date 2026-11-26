require "./support"

private alias Codec = Mica::Encoding::Codec
private alias ErrorMode = Mica::Encoding::ErrorMode
private alias Converter = Mica::Encoding::Decoder | Mica::Encoding::Encoder

private SEED   = ENV["MICA_ENCODING_SEED"]?.try(&.to_u64) || 20261126_u64
private ROUNDS = ENV["MICA_ENCODING_ROUNDS"]?.try(&.to_i) || 150

private UTF16_CODECS = [Codec::UTF16, Codec::UTF16LE, Codec::UTF16BE, Codec::UCS2, Codec::UCS2LE, Codec::UCS2BE]

# Everything one run of a converter over a whole input produced: the
# output bytes, every fatal problem as {problem, offset, code point}, the
# status of the final call, and the converter's position at the end.
private record Transcript,
  output : Bytes,
  list_of_problems : Array({Mica::Encoding::Problem?, Int64, Int32}),
  final_status : Mica::Encoding::Status,
  position : Int64

# Feeds *input* to *converter* in chunks whose sizes *chunk_size* yields,
# into output buffers of *output_size* bytes, going on after each fatal
# problem (the converter has reset itself) until the input is consumed.
private def run_converter(converter : Converter, input : Bytes, output_size : Int32, & : Int32 -> Int32) : Transcript
  output = IO::Memory.new
  buffer = Bytes.new(output_size)
  list_of_problems = [] of {Mica::Encoding::Problem?, Int64, Int32}
  offset = 0
  final_status = Mica::Encoding::Status::InputEmpty
  loop do
    remaining = input.size - offset
    chunk_size = remaining == 0 ? 0 : (yield remaining).clamp(1, remaining)
    last = offset + chunk_size == input.size
    chunk = input[offset, chunk_size]
    loop do
      result = converter.convert(chunk, buffer, last)
      output.write(buffer[0, result.written])
      chunk = chunk[result.read..]
      offset += result.read
      final_status = result.status
      if result.error?
        list_of_problems << {result.problem, result.offset, result.code_point}
        next
      end
      break unless result.output_full?
    end
    break if last
  end
  Transcript.new(output.to_slice, list_of_problems, final_status, converter.position)
end

# The reference: one byte per call, which keeps the converters on their
# per-byte paths.
private def run_byte_by_byte(converter : Converter, input : Bytes) : Transcript
  run_converter(converter, input, Mica::Encoding::MIN_OUTPUT_BYTES) { 1 }
end

private def put_unit(io : IO, unit : Int32, big_endian : Bool) : Nil
  if big_endian
    io.write_byte((unit >> 8).to_u8!)
    io.write_byte(unit.to_u8!)
  else
    io.write_byte(unit.to_u8!)
    io.write_byte((unit >> 8).to_u8!)
  end
end

# UTF-16 bytes: ASCII runs long enough for the wide steps, BMP text,
# surrogate pairs, lone surrogates of both kinds, byte order marks in
# both orders, and sometimes a stray odd byte at the end.
private def random_utf16_bytes(random : Random, big_endian : Bool) : Bytes
  io = IO::Memory.new
  random.rand(0..40).times do
    case random.rand(14)
    when 0..3
      random.rand(1..24).times { put_unit(io, random.rand(0x00..0x7F), big_endian) }
    when 4 then put_unit(io, random.rand(0x80..0x7FF), big_endian)
    when 5 then put_unit(io, random.rand(0x800..0xD7FF), big_endian)
    when 6 then put_unit(io, random.rand(0xE000..0xFFFF), big_endian)
    when 7, 8
      code_point = random.rand(0x10000..0x10FFFF) - 0x10000
      put_unit(io, 0xD800 | (code_point >> 10), big_endian)
      put_unit(io, 0xDC00 | (code_point & 0x3FF), big_endian)
    when 9  then put_unit(io, random.rand(0xD800..0xDBFF), big_endian)
    when 10 then put_unit(io, random.rand(0xDC00..0xDFFF), big_endian)
    when 11 then put_unit(io, {0xFEFF, 0xFFFE}.sample(random), big_endian)
    when 12 then io.write_byte(random.rand(0x00_u8..0xFF_u8))
    else         put_unit(io, {0x00, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFD}.sample(random), big_endian)
    end
  end
  io.write_byte(random.rand(0x00_u8..0xFF_u8)) if random.rand(4) == 0
  io.to_slice
end

# UTF-8 bytes: long ASCII runs, text from several scripts, U+FEFF,
# characters above U+FFFF, and ill-formed or cut-off sequences.
private def random_utf8_bytes(random : Random) : Bytes
  io = IO::Memory.new
  random.rand(0..30).times do
    case random.rand(10)
    when 0..3
      random.rand(1..40).times { io.write_byte(random.rand(0x00_u8..0x7F_u8)) }
    when 4 then io.write(random_encoding_text(random, 6))
    when 5 then io << random.rand(0x10000..0x10FFFF).chr
    when 6 then io << '\u{FEFF}'
    when 7
      # A valid sequence cut short.
      bytes = {random.rand(0x80..0xD7FF), random.rand(0xE000..0x10FFFF)}.sample(random).chr.to_s.to_slice
      bytes = bytes[0, random.rand(1...bytes.size)] if bytes.size > 1
      io.write(bytes)
    when 8
      random.rand(1..3).times { io.write_byte({0xC0, 0xC1, 0xE0, 0x80, 0xED, 0xA0, 0xF0, 0x8F, 0xF4, 0x90, 0xF5, 0xFF, 0xBF}.sample(random).to_u8) }
    else
      io << {random.rand(0x800..0xD7FF), random.rand(0xE000..0xFFFF)}.sample(random).chr
    end
  end
  io.to_slice
end

private def expect_same(actual : Transcript, expected : Transcript, label : String) : Nil
  unless actual == expected
    fail "#{label}\n  expected #{expected.inspect}\n  got      #{actual.inspect}"
  end
end

describe "Mica::Encoding UTF-16 fast paths" do
  it "decode the same as the per-byte path for random input, chunking and output room (seed #{SEED})" do
    random = Random::PCG32.new(SEED)
    cases = 0
    UTF16_CODECS.each do |codec|
      big_endian = codec.utf16_be? || codec.ucs2_be?
      ErrorMode.values.each do |mode|
        {false, true}.each do |strip_bom|
          ROUNDS.times do
            input = random_utf16_bytes(random, big_endian)
            expected = run_byte_by_byte(codec.decoder(mode, strip_bom), input)
            label = "#{codec} #{mode} strip_bom=#{strip_bom} input=#{input.hexstring}"
            whole = run_converter(codec.decoder(mode, strip_bom), input, input.size * 3 + 64) { |remaining| remaining }
            expect_same(whole, expected, "#{label} (whole)")
            tight = run_converter(codec.decoder(mode, strip_bom), input, Mica::Encoding::MIN_OUTPUT_BYTES) { |remaining| random.rand(1..remaining) }
            expect_same(tight, expected, "#{label} (random chunks, MIN_OUTPUT_BYTES)")
            roomy = run_converter(codec.decoder(mode, strip_bom), input, random.rand(16..80)) { |remaining| random.rand(1..remaining) }
            expect_same(roomy, expected, "#{label} (random chunks and room)")
            cases += 1
          end
        end
      end
    end
    cases.should eq(UTF16_CODECS.size * ErrorMode.values.size * 2 * ROUNDS)
  end

  it "encode the same as the per-byte path for random input, chunking and output room (seed #{SEED})" do
    random = Random::PCG32.new(SEED &+ 1)
    UTF16_CODECS.each do |codec|
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          input = random_utf8_bytes(random)
          expected = run_byte_by_byte(codec.encoder(mode), input)
          label = "#{codec} #{mode} input=#{input.hexstring}"
          whole = run_converter(codec.encoder(mode), input, input.size * 2 + 64) { |remaining| remaining }
          expect_same(whole, expected, "#{label} (whole)")
          tight = run_converter(codec.encoder(mode), input, Mica::Encoding::MIN_OUTPUT_BYTES) { |remaining| random.rand(1..remaining) }
          expect_same(tight, expected, "#{label} (random chunks, MIN_OUTPUT_BYTES)")
          roomy = run_converter(codec.encoder(mode), input, random.rand(16..80)) { |remaining| random.rand(1..remaining) }
          expect_same(roomy, expected, "#{label} (random chunks and room)")
        end
      end
    end
  end

  it "report an unpaired surrogate's restored unit at its own offset when its first byte came in an earlier call" do
    # D800 then D801 'a': in Fatal mode the second problem is the lead at
    # byte 2, however the input is split.
    input = Bytes[0x00, 0xD8, 0x01, 0xD8, 0x61, 0x00]
    expected = [{Mica::Encoding::Problem::InvalidSequence, 0_i64, -1}, {Mica::Encoding::Problem::InvalidSequence, 2_i64, -1}]
    run_byte_by_byte(Codec::UTF16LE.decoder(ErrorMode::Fatal), input).list_of_problems.should eq(expected)
    run_converter(Codec::UTF16LE.decoder(ErrorMode::Fatal), input, 64) { |remaining| remaining }.list_of_problems.should eq(expected)
  end

  it "finish valid input in one call within the documented output bound" do
    random = Random::PCG32.new(SEED &+ 2)
    UTF16_CODECS.each do |codec|
      big_endian = codec.utf16_be? || codec.ucs2_be?
      ROUNDS.times do
        input = random_utf16_bytes(random, big_endian)
        bound = codec.max_decoded_size(input.size).to_i32 + Mica::Encoding::MIN_OUTPUT_BYTES
        result = codec.decoder(ErrorMode::Replacement).convert(input, Bytes.new(bound), last: true)
        result.status.should eq(Mica::Encoding::Status::InputEmpty)
        result.read.should eq(input.size)

        text = random_utf8_bytes(random)
        bound = codec.max_encoded_size(text.size, ErrorMode::Replacement).to_i32 + Mica::Encoding::MIN_OUTPUT_BYTES
        result = codec.encoder(ErrorMode::Replacement).convert(text, Bytes.new(bound), last: true)
        result.status.should eq(Mica::Encoding::Status::InputEmpty)
        result.read.should eq(text.size)
      end
    end
  end

  it "round-trips valid text against the standard library's UTF-16" do
    random = Random::PCG32.new(SEED &+ 3)
    ROUNDS.times do
      text = String.new(random_encoding_text(random, 80)).scrub
      units = text.to_utf16
      little = Bytes.new(units.size * 2)
      big = Bytes.new(units.size * 2)
      units.each_with_index do |unit, index|
        little[2 * index] = unit.to_u8!
        little[2 * index + 1] = (unit >> 8).to_u8!
        big[2 * index] = (unit >> 8).to_u8!
        big[2 * index + 1] = unit.to_u8!
      end
      Mica::Encoding.encode(text, Codec::UTF16LE).should eq(little)
      Mica::Encoding.encode(text, Codec::UTF16BE).should eq(big)
      Mica::Encoding.decode(little, Codec::UTF16LE).should eq(text)
      Mica::Encoding.decode(big, Codec::UTF16BE).should eq(text)
    end
  end
end
