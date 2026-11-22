require "./deflate_tokens"
require "../../../fuzz/deflate_oracle"

# Inputs and decoders shared by the encoder specs (spec/deflate/encoder_spec.cr
# and spec/deflate/writer_spec.cr). Every input is built from a fixed seed.
module EncoderSamples
  LIMITS = Mica::Deflate::DecodeLimits::TRUSTED_ASSET
  WORDS  = %w[the of and a to in is you that it he was for on are as with his they I at be this have from or one had
    by word but not what all were we when your can said there use an each which she do how their if will up other
    about out many then them these so some her would make like him into time has look two more write go see number
    no way could people my than first water been call who oil its now find long down day did get come made may part
    compress window deflate stream header block literal distance length gzip zlib Amber Crystal request response]

  # Bytes that compress like prose: seeded words, spaces and line breaks.
  def self.text(size : Int32, seed : Int32 = 1) : Bytes
    random = Random.new(seed)
    io = IO::Memory.new(size + 16)
    while io.pos < size
      io << WORDS[random.rand(WORDS.size)]
      io << (random.rand(12) == 0 ? ".\n" : " ")
    end
    io.to_slice[0, size].dup
  end

  # Bytes with no structure to compress.
  def self.random_bytes(size : Int32, seed : Int32 = 1) : Bytes
    Random.new(seed).random_bytes(size)
  end

  # Long runs of single bytes and of short patterns.
  def self.runs(size : Int32) : Bytes
    io = IO::Memory.new(size + 1_024)
    period = 1
    while io.pos < size
      pattern = Bytes.new(period) { |index| (65 + (index + period) % 26).to_u8 }
      (3_000 // period + 1).times { io.write(pattern) }
      period = period % 9 + 1
    end
    io.to_slice[0, size].dup
  end

  # One prefix byte, 32,768 random bytes, then those bytes again: every
  # match in the second half lies exactly 32,768 bytes back and can run
  # to 258 bytes.
  def self.repeat_at_the_window_edge : Bytes
    block = random_bytes(32_768, 7)
    io = IO::Memory.new
    io.write_byte(0x2A_u8)
    io.write(block)
    io.write(block)
    io.to_slice.dup
  end

  # Returns the parts as one slice.
  def self.join(*parts : Bytes) : Bytes
    io = IO::Memory.new
    parts.each { |part| io.write(part) }
    io.to_slice
  end

  # The inputs every level and container must round-trip.
  def self.each_named_input(& : String, Bytes ->) : Nil
    yield "an empty input", Bytes.empty
    yield "one byte", Bytes[0x41]
    yield "a short text", "Hello, hello, hello: DEFLATE says hello.".to_slice
    yield "long runs", runs(70_000)
    yield "incompressible random bytes", random_bytes(40_000)
    yield "text longer than the window", text(120_000)
    yield "a repeat 32,768 bytes back", repeat_at_the_window_edge
  end

  def self.encode(format : DeflateOracle::Format, input : Bytes, level : Int32) : Bytes
    case format
    in .raw?  then Mica::Deflate.encode(input, level: level)
    in .zlib? then Mica::Zlib.encode(input, level: level)
    in .gzip? then Mica::Gzip.encode(input, level: level)
    end
  end

  def self.decode_with_mica(format : DeflateOracle::Format, stream : Bytes, dictionary : Bytes? = nil) : Bytes
    case format
    in .raw?  then Mica::Deflate.decode(stream, limits: LIMITS, timeout: nil)
    in .zlib? then Mica::Zlib.decode(stream, limits: LIMITS, timeout: nil, dictionary: dictionary)
    in .gzip? then Mica::Gzip.decode(stream, limits: LIMITS, timeout: nil)
    end
  end

  # Decodes with the system zlib and requires that it accepted the whole
  # stream.
  def self.decode_with_zlib(format : DeflateOracle::Format, stream : Bytes, dictionary : Bytes? = nil) : Bytes
    result = DeflateOracle.decode(format, stream, dictionary)
    raise "system zlib rejected the stream: #{result.detail}" unless result.accepted?
    result.output
  end

  def self.writer(format : DeflateOracle::Format, io : IO, level : Int32) : Mica::Deflate::StreamWriter
    case format
    in .raw?  then Mica::Deflate::Writer.new(io, level: level)
    in .zlib? then Mica::Zlib::Writer.new(io, level: level)
    in .gzip? then Mica::Gzip::Writer.new(io, level: level)
    end
  end

  # The raw DEFLATE data inside a zlib stream without a dictionary or a
  # gzip member with the default header.
  def self.raw_part(format : DeflateOracle::Format, stream : Bytes) : Bytes
    case format
    in .raw?  then stream
    in .zlib? then stream[2, stream.size - 6]
    in .gzip? then stream[10, stream.size - 18]
    end
  end
end
