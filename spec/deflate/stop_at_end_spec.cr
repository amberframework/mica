require "./support/bit_writer"
# The vector specs register their vectors when they load; this file replays
# the valid raw and zlib ones with data after the stream.
require "./inflate_spec"
require "./zlib_spec"

# Specs for `stop_at_end:` on `Mica::Deflate::Reader` and `Mica::Zlib::Reader`:
# the reader takes from its source exactly the bytes of the stream, so what
# follows the stream is still in the source, whether the source has `peek`
# (and shows any window size) or not.

# A source whose `peek` shows at most *window* bytes and whose reads return
# at most *window* bytes, like an `IO::Buffered` with a small buffer.
private class WindowedIO < IO
  def initialize(@bytes : Bytes, @window : Int32)
    @offset = 0
  end

  def peek : Bytes
    @bytes[@offset, Math.min(@window, @bytes.size - @offset)]
  end

  def read(slice : Bytes) : Int32
    count = Math.min(Math.min(@window, slice.size), @bytes.size - @offset)
    return 0 if count <= 0
    slice[0, count].copy_from(@bytes[@offset, count])
    @offset += count
    count
  end

  def skip(bytes_count : Int) : Nil
    raise IO::EOFError.new if bytes_count > @bytes.size - @offset
    @offset += bytes_count
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

private TRAILING = "after the stream".to_slice

private LIST_OF_WINDOWS = {1, 2, 3, 7, 8, 9, 15, 16, 17, 64, 4_096, 100_000}

# Every source shape a reader meets: windowed peeks of each size, and a
# source with no `peek` at all (read one byte at a time).
private def each_source(input : Bytes, &)
  LIST_OF_WINDOWS.each { |window| yield WindowedIO.new(input, window), "a peek window of #{window}" }
  yield TrickleIO.new(input, 4_096), "a source without peek"
end

private def stopping_reader(format : DeflateConformance::Format, io : IO, dictionary : Bytes? = nil) : IO
  if format.raw?
    Mica::Deflate::Reader.new(io, limits: DeflateConformance::LIMITS, timeout: nil, dictionary: dictionary, stop_at_end: true)
  else
    Mica::Zlib::Reader.new(io, limits: DeflateConformance::LIMITS, timeout: nil, dictionary: dictionary, stop_at_end: true)
  end
end

# Decodes *input* (a stream followed by *trailing*) through every source
# shape and checks the output and that exactly *trailing* is left.
private def check_stops_at_end(format : DeflateConformance::Format, input : Bytes, expected : Bytes,
                               trailing : Bytes, dictionary : Bytes? = nil, label : String = "") : Nil
  joined = DeflateConformance.join(input, trailing)
  each_source(joined) do |source, how|
    reader = stopping_reader(format, source, dictionary)
    output = reader.getb_to_end
    fail "#{label} through #{how}: output differs (#{output.size} bytes, expected #{expected.size})" unless output == expected
    rest = source.getb_to_end
    fail "#{label} through #{how}: left #{rest.size} bytes, expected #{trailing.size}" unless rest == trailing
  end
end

describe "Mica::Deflate stop_at_end" do
  it_satisfies "DEFLATE-API-stop-at-end", "leaves what follows every valid raw and zlib conformance vector in the source" do
    count = 0
    DeflateConformance::LIST_OF_VECTORS.each_with_index do |vector, index|
      next if vector.format.gzip?
      expected = vector.expected
      next unless expected.is_a?(Bytes)
      check_stops_at_end(vector.format, vector.input, expected, TRAILING, vector.dictionary, "#{vector.format} vector #{index} (#{vector.label})")
      count += 1
    end
    count.should be > 100
  end

  it_satisfies "DEFLATE-API-stop-at-end", "leaves the data after encoder output of every level, with any trailing bytes" do
    random = Random.new(20261123)
    {0, 1, 2, 100, 258, 4_095, 33_000, 70_000, 200_000}.each do |size|
      sample = DeflateConformance.sample_bytes(size)
      noise = Bytes.new(size) { random.rand(256).to_u8 }
      {sample, noise}.each do |content|
        (0..9).each do |level|
          trailing = Bytes.new(random.rand(0..12)) { random.rand(256).to_u8 }
          check_stops_at_end(DeflateConformance::Format::Raw, Mica::Deflate.encode(content, level: level), content, trailing,
            label: "raw, #{size} bytes, level #{level}")
          check_stops_at_end(DeflateConformance::Format::Zlib, Mica::Zlib.encode(content, level: level), content, trailing,
            label: "zlib, #{size} bytes, level #{level}")
        end
      end
    end
  end

  it_satisfies "DEFLATE-API-stop-at-end", "leaves a gzip-style trailer for the caller after a flushed stream" do
    content = DeflateConformance.sample_bytes(50_000)
    stream = IO::Memory.new
    writer = Mica::Deflate::Writer.new(stream, level: 6)
    writer.write(content[0, 20_000])
    writer.flush
    writer.write(content[20_000, 30_000])
    writer.close
    trailer = Bytes.new(8) { |index| (index * 31).to_u8 }
    check_stops_at_end(DeflateConformance::Format::Raw, stream.to_slice, content, trailer, label: "flushed stream")
  end

  it_satisfies "DEFLATE-API-stop-at-end", "decodes a raw stream from the preset dictionary it is given" do
    dictionary = "the quick brown fox jumps over the lazy dog ".to_slice
    content = ("the lazy dog and the quick fox " * 40).to_slice
    stream = IO::Memory.new
    writer = Mica::Deflate::Writer.new(stream, level: 6, dictionary: dictionary)
    writer.write(content)
    writer.close
    stream.size.should be < content.size // 4
    check_stops_at_end(DeflateConformance::Format::Raw, stream.to_slice, content, TRAILING, dictionary, "raw with a dictionary")
  end

  it_satisfies "DEFLATE-API-stop-at-end", "raises at a truncated stream as the one-shot decode does" do
    content = DeflateConformance.sample_bytes(10_000)
    input = Mica::Deflate.encode(content, level: 6)
    {1, input.size // 2, input.size - 1}.each do |cut|
      each_source(input[0, cut]) do |source, _how|
        expect_raises(Mica::Deflate::TruncatedStreamError) do
          stopping_reader(DeflateConformance::Format::Raw, source).getb_to_end
        end
      end
    end
  end
end
