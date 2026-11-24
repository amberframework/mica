require "digest/sha256"
require "../spec_helper"

# Pinned conformance data (conformance/encoding/MANIFEST), fetched by
# `/usr/bin/ruby conformance/encoding/fetch_vectors.rb`.
module EncodingVectors
  ROOT     = File.expand_path("../../conformance/encoding-vectors", __DIR__)
  MANIFEST = File.expand_path("../../conformance/encoding/MANIFEST", __DIR__)

  class MismatchError < Exception
  end

  # Returns the sha256 each manifest path must have, keyed "source/path".
  def self.pins : Hash(String, String)
    pins = {} of String => String
    File.each_line(MANIFEST) do |line|
      next if line.empty? || line.starts_with?('#')
      source, path, sha256 = line.split
      pins["#{source}/#{path}"] = sha256
    end
    pins
  end

  # Reads a pinned file after checking its sha256; raises naming the file
  # when it is missing or altered.
  def self.read(relative : String) : String
    expected = pins[relative]? || raise MismatchError.new("#{relative} is not pinned in conformance/encoding/MANIFEST")
    path = File.join(ROOT, relative)
    unless File.exists?(path)
      raise MismatchError.new("#{relative} is missing: run /usr/bin/ruby conformance/encoding/fetch_vectors.rb")
    end
    content = File.read(path)
    actual = Digest::SHA256.hexdigest(content)
    unless actual == expected
      raise MismatchError.new("sha256 mismatch for #{relative}: expected #{expected}, got #{actual}")
    end
    content
  end

  # Returns an index file's {pointer, code point} entries in file order.
  def self.index(name : String) : Array({Int32, Int32})
    read("whatwg/index-#{name}.txt").each_line.compact_map do |line|
      next if line.strip.empty? || line.starts_with?('#')
      fields = line.split('\t')
      {fields[0].strip.to_i, fields[1].strip.to_i(prefix: true)}
    end.to_a
  end
end

# Converts *input* through *decoder* fed in the chunk sizes *splits*
# yields, into output buffers of *output_size* bytes. Returns the output
# and the first fatal result, if any.
def convert_in_chunks(converter : Mica::Encoding::Decoder | Mica::Encoding::Encoder, input : Bytes, random : Random, output_size : Int32) : {Bytes, Mica::Encoding::Result?}
  output = IO::Memory.new
  buffer = Bytes.new(output_size)
  offset = 0
  loop do
    chunk_size = input.size - offset == 0 ? 0 : random.rand(1..(input.size - offset))
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

# Bytes biased toward the edges every decoder cares about.
def random_encoding_bytes(random : Random, max_size : Int32 = 64) : Bytes
  edges = Bytes[0x00, 0x0E, 0x0F, 0x1B, 0x24, 0x28, 0x30, 0x39, 0x40, 0x42, 0x49, 0x4A, 0x5C, 0x7E, 0x7F, 0x80, 0x81,
    0x8E, 0x8F, 0xA0, 0xA1, 0xBF, 0xC0, 0xC2, 0xD8, 0xDB, 0xDC, 0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFE, 0xFF]
  Bytes.new(random.rand(0..max_size)) do
    case random.rand(10)
    when 0..2 then random.rand(0x20_u8..0x7E_u8)
    when 3..7 then random.rand(0x80_u8..0xFF_u8)
    else           edges[random.rand(edges.size)]
    end
  end
end

# UTF-8 input for encoders: mostly valid text from several scripts, with
# some ill-formed bytes.
def random_encoding_text(random : Random, max_chars : Int32 = 24) : Bytes
  io = IO::Memory.new
  random.rand(0..max_chars).times do
    case random.rand(12)
    when 0..3 then io << random.rand(0x20..0x7E).chr
    when 4    then io << random.rand(0xA0..0x24F).chr
    when 5    then io << random.rand(0x3040..0x30FF).chr
    when 6    then io << random.rand(0x4E00..0x9FFF).chr
    when 7    then io << random.rand(0xAC00..0xD7A3).chr
    when 8    then io << {0xA5, 0x203E, 0x2212, 0xFF61, 0xFF9F, 0x20AC, 0xE5E5, 0xCA, 0xEA, 0x304, 0x30C, 0xFEFF, 0x1B, 0x0E}.sample(random).chr
    when 9    then io << random.rand(0x10000..0x10FFFF).chr
    when 10   then io.write_byte(random.rand(0x80_u8..0xFF_u8))
    else           io << random.rand(0x400..0x4FF).chr
    end
  end
  io.to_slice
end
