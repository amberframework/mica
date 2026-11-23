# Release-build fuzz campaign over Mica::Encoding: random and mutated
# inputs through every decoder and encoder in every error mode, each fed
# whole and in random chunks into random output sizes.
#
#   crystal-alpha build --release fuzz/encoding_campaign.cr -o bin/encoding_campaign
#   bin/encoding_campaign SEED ITERATIONS [iso-2022-jp]
#
# A case fails when a converter raises anything but ConversionError,
# when the chunked output differs from the whole one, when the output
# exceeds the codec's documented bound, or when it takes more than 10 ms
# per KiB. With `iso-2022-jp`, every iteration is a random sequence of
# ISO-2022-JP escapes and bytes (the stateful decoder's worst case).
# Prints one summary line and every failure (replayable as SEED:ITERATION).
require "../src/mica/encoding"

module EncodingFuzz
  EDGES = Bytes[0x00, 0x0E, 0x0F, 0x1B, 0x24, 0x28, 0x30, 0x39, 0x40, 0x42, 0x49, 0x4A, 0x5C, 0x7E, 0x7F, 0x80, 0x81,
    0x8E, 0x8F, 0xA0, 0xA1, 0xBF, 0xC0, 0xC2, 0xD8, 0xDB, 0xDC, 0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFE, 0xFF]
  ESCAPES = [Bytes[0x1B, 0x28, 0x42], Bytes[0x1B, 0x28, 0x4A], Bytes[0x1B, 0x28, 0x49], Bytes[0x1B, 0x24, 0x40],
             Bytes[0x1B, 0x24, 0x42], Bytes[0x1B, 0x28], Bytes[0x1B, 0x24], Bytes[0x1B], Bytes[0x0E], Bytes[0x0F]]

  def self.random_input(random : Random, size : Int32, escapes : Bool) : Bytes
    io = IO::Memory.new
    while io.size < size
      roll = random.rand(20)
      if escapes && roll < 6
        io.write(ESCAPES[random.rand(ESCAPES.size)])
      elsif roll < 9
        io.write_byte(random.rand(0x20_u8..0x7E_u8))
      elsif roll < 17
        io.write_byte(random.rand(0x80_u8..0xFF_u8))
      elsif roll < 19
        io.write_byte(EDGES[random.rand(EDGES.size)])
      else
        code_point = random.rand(0x80..0x10FFFF)
        io << code_point.chr unless 0xD800 <= code_point <= 0xDFFF
      end
    end
    io.to_slice
  end

  # Runs *converter* over *input* in random chunks; returns the output and
  # the first fatal result.
  def self.run(converter, input : Bytes, random : Random?, output_size : Int32) : {Bytes, Mica::Encoding::Result?}
    output = IO::Memory.new
    buffer = Bytes.new(output_size)
    offset = 0
    loop do
      remaining = input.size - offset
      chunk_size = random && remaining > 0 ? random.rand(1..remaining) : remaining
      last = offset + chunk_size == input.size
      chunk = input[offset, chunk_size]
      loop do
        result = converter.convert(chunk, buffer, last)
        output.write(buffer[0, result.written])
        chunk = chunk[result.read..]
        offset += result.read
        return {output.to_slice, result} if result.error?
        break unless result.output_full?
      end
      break if last
    end
    {output.to_slice, nil}
  end
end

seed = (ARGV[0]? || abort("usage: encoding_campaign SEED ITERATIONS [iso-2022-jp]")).to_u64
iterations = (ARGV[1]? || abort("usage: encoding_campaign SEED ITERATIONS [iso-2022-jp]")).to_i
escapes_only = ARGV[2]? == "iso-2022-jp"
codecs = escapes_only ? [Mica::Encoding::Codec::ISO2022JP] : Mica::Encoding::Codec.values
modes = Mica::Encoding::ErrorMode.values

failures = [] of String
crashes = 0
mismatches = 0
overruns = 0
slow = 0
bytes_converted = 0_i64
started = Time.instant
iterations.times do |iteration|
  random = Random::PCG32.new(seed, iteration.to_u64)
  codec = codecs[random.rand(codecs.size)]
  mode = modes[random.rand(modes.size)]
  input = EncodingFuzz.random_input(random, random.rand(0..(escapes_only ? 64 : 512)), escapes_only || codec.iso2022_jp?)
  bytes_converted += input.size
  {:decode, :encode}.each do |direction|
    next if direction == :encode && !codec.encodes?
    make = -> { direction == :decode ? codec.decoder(mode).as(Mica::Encoding::Decoder | Mica::Encoding::Encoder) : codec.encoder(mode).as(Mica::Encoding::Decoder | Mica::Encoding::Encoder) }
    begin
      case_started = Time.instant
      whole, whole_error = EncodingFuzz.run(make.call, input, nil, input.size * 8 + 64)
      elapsed = Time.instant - case_started
      chunked, chunked_error = EncodingFuzz.run(make.call, input, random, random.rand(16..48))
      if whole != chunked || whole_error.try(&.offset) != chunked_error.try(&.offset)
        mismatches += 1
        failures << "#{seed}:#{iteration} #{codec} #{mode} #{direction} chunked output differs"
      end
      bound = direction == :decode ? codec.max_decoded_size(input.size) : codec.max_encoded_size(input.size, mode)
      if whole.size > bound
        overruns += 1
        failures << "#{seed}:#{iteration} #{codec} #{mode} #{direction} wrote #{whole.size} > bound #{bound}"
      end
      if elapsed.total_milliseconds > 10.0 * Math.max(1.0, input.size / 1024.0)
        slow += 1
        failures << "#{seed}:#{iteration} #{codec} #{mode} #{direction} took #{elapsed.total_milliseconds.round(2)} ms for #{input.size} bytes"
      end
    rescue error
      crashes += 1
      failures << "#{seed}:#{iteration} #{codec} #{mode} #{direction} raised #{error.class}: #{error.message}"
    end
  end
end
seconds = (Time.instant - started).total_seconds
puts "seed=#{seed} iterations=#{iterations} codecs=#{codecs.size} input_bytes=#{bytes_converted} crashes=#{crashes} chunking_mismatches=#{mismatches} bound_overruns=#{overruns} slow_cases=#{slow} seconds=#{seconds.round(1)}"
failures.sort_by! { |line| line.includes?(" raised ") ? 0 : 1 }
failures.first(50).each { |line| puts "  FAIL #{line}" }
exit(failures.empty? ? 0 : 1)
