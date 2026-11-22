require "./support/encoder_samples"

# Specs for the streaming encoders, `Mica::Deflate::Writer`,
# `Mica::Zlib::Writer` and `Mica::Gzip::Writer` (milestone Z2): chunking,
# `flush`, `full_flush`, `close`, the preset dictionary and the errors of
# a closed writer. Requirement catalog:
# spec/requirements/deflate_encoder.tsv.

private FORMATS = [DeflateOracle::Format::Raw, DeflateOracle::Format::Zlib, DeflateOracle::Format::Gzip]

# An IO that records whether it was flushed and closed.
private class RecordingIO < IO::Memory
  getter flush_count = 0

  def flush : Nil
    @flush_count += 1
    super
  end
end

# An IO that discards what is written to it.
private class DiscardingIO < IO
  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
  end
end

# Writes *input* through a writer in pieces whose sizes *next_size* gives.
private def encode_in_pieces(format : DeflateOracle::Format, input : Bytes, level : Int32, & : -> Int32) : Bytes
  io = IO::Memory.new
  writer = EncoderSamples.writer(format, io, level)
  offset = 0
  while offset < input.size
    size = Math.min(yield, input.size - offset)
    writer.write(input[offset, size])
    offset += size
  end
  writer.close
  io.to_slice
end

# A complete raw DEFLATE stream made of *prefix* (which must end on a byte
# boundary without a final block) and an empty final block.
private def completed(prefix : Bytes) : Bytes
  EncoderSamples.join(prefix, Bytes[0x03, 0x00])
end

describe "Mica::Deflate encoders, streaming" do
  describe "#write" do
    EncoderSamples.each_named_input do |name, input|
      it_satisfies({"DEFLATE-ENC-ROUNDTRIP-mica", "DEFLATE-ENC-ROUNDTRIP-zlib", "DEFLATE-ENC-ROUNDTRIP-edge-inputs"},
        "round-trips #{name} written in 1,000-byte pieces at every level, in every container") do
        FORMATS.each do |format|
          0.upto(9) do |level|
            stream = encode_in_pieces(format, input, level) { 1_000 }
            EncoderSamples.decode_with_mica(format, stream).should eq(input)
            EncoderSamples.decode_with_zlib(format, stream).should eq(input)
          end
        end
      end
    end

    it_satisfies "DEFLATE-ENC-API-chunking", "decodes to the same bytes after one write, one-byte writes and random-size writes" do
      input = EncoderSamples.join(EncoderSamples.text(60_000, 23), EncoderSamples.runs(20_000), EncoderSamples.random_bytes(8_000, 3))
      FORMATS.each do |format|
        {0, 1, 5, 9}.each do |level|
          random = Random.new(level + 1)
          in_one_write = encode_in_pieces(format, input, level) { input.size }
          byte_by_byte = encode_in_pieces(format, input, level) { 1 }
          in_random_pieces = encode_in_pieces(format, input, level) { random.rand(1..5_000) }
          {in_one_write, byte_by_byte, in_random_pieces}.each do |stream|
            EncoderSamples.decode_with_mica(format, stream).should eq(input)
            EncoderSamples.decode_with_zlib(format, stream).should eq(input)
          end
          # How the input arrives does not change what is written.
          byte_by_byte.should eq(in_one_write)
          in_random_pieces.should eq(in_one_write)
        end
      end
    end

    it_satisfies "DEFLATE-ENC-API-chunking", "writes the stream the one-shot encoder writes" do
      input = EncoderSamples.text(30_000, 29)
      FORMATS.each do |format|
        {0, 1, 6, 9}.each do |level|
          streamed = encode_in_pieces(format, input, level) { 777 }
          streamed.should eq(EncoderSamples.encode(format, input, level))
        end
      end
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.5-match-limits", "reaches 32,768 bytes back across window slides" do
      input = EncoderSamples.join(EncoderSamples.repeat_at_the_window_edge, EncoderSamples.random_bytes(32_768, 7),
        EncoderSamples.random_bytes(32_768, 7))
      {1, 6, 9}.each do |level|
        stream = encode_in_pieces(DeflateOracle::Format::Raw, input, level) { 4_096 }
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Raw, stream).should eq(input)
        list_of_matches = DeflateTokens.read(stream).flat_map(&.list_of_matches)
        list_of_matches.count { |match| match.length == 258 && match.distance == 32_768 }.should be >= 370
        stream.size.should be < 32_769 + 3_000
      end
    end

    it_satisfies "DEFLATE-ENC-API-levels", "raises ArgumentError for a level outside 0 to 9" do
      {-1, 10}.each do |level|
        expect_raises(ArgumentError, "Invalid compression level #{level}") { Mica::Deflate::Writer.new(IO::Memory.new, level: level) }
        expect_raises(ArgumentError, "Invalid compression level #{level}") { Mica::Zlib::Writer.new(IO::Memory.new, level: level) }
        expect_raises(ArgumentError, "Invalid compression level #{level}") { Mica::Gzip::Writer.new(IO::Memory.new, level: level) }
      end
    end

    it "is an IO: print, puts and IO.copy write through it" do
      io = IO::Memory.new
      writer = Mica::Gzip::Writer.new(io)
      writer << "first line\n"
      writer.puts "second line"
      IO.copy(IO::Memory.new("third line\n"), writer)
      writer.close
      String.new(EncoderSamples.decode_with_zlib(DeflateOracle::Format::Gzip, io.to_slice)).should eq("first line\nsecond line\nthird line\n")
    end
  end

  describe "#flush" do
    it_satisfies "DEFLATE-ENC-API-flush", "makes everything written so far decodable and ends on a byte boundary" do
      first = EncoderSamples.text(40_000, 37)
      second = EncoderSamples.text(25_000, 38)
      0.upto(9) do |level|
        io = RecordingIO.new
        writer = Mica::Deflate::Writer.new(io, level: level)
        writer.write(first)
        writer.flush
        io.flush_count.should eq(1)
        flushed = io.to_slice.dup
        flushed[-4, 4].should eq(Bytes[0x00, 0x00, 0xFF, 0xFF])
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Raw, completed(flushed)).should eq(first)
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Raw, completed(flushed)).should eq(first)
        writer.write(second)
        writer.close
        io.to_slice[0, flushed.size].should eq(flushed)
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Raw, io.to_slice).should eq(EncoderSamples.join(first, second))
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Raw, io.to_slice).should eq(EncoderSamples.join(first, second))
      end
    end

    it_satisfies "DEFLATE-ENC-API-flush", "lets a streaming reader see each flushed piece before the stream ends" do
      {1, 6}.each do |level|
        io = IO::Memory.new
        writer = Mica::Zlib::Writer.new(io, level: level)
        decoded = IO::Memory.new
        consumed = 0
        ["event: one\n\n", "event: two\n\n", "event: three\n\n"].each do |piece|
          writer << piece
          writer.flush
          # zlib decodes exactly the bytes written so far from the output so far.
          result = DeflateOracle.decode(DeflateOracle::Format::Zlib, io.to_slice)
          result.rejection.should eq(DeflateOracle::Rejection::Truncated)
          decoded << piece
          result.output.should eq(decoded.to_slice)
          io.to_slice.size.should be > consumed
          consumed = io.to_slice.size
        end
        writer.close
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Zlib, io.to_slice).should eq(decoded.to_slice)
      end
    end

    it_satisfies "DEFLATE-ENC-API-flush", "adds no bytes when nothing was written since the last flush" do
      FORMATS.each do |format|
        {0, 6}.each do |level|
          io = IO::Memory.new
          writer = EncoderSamples.writer(format, io, level)
          writer.write("flush twice".to_slice)
          writer.flush
          size = io.to_slice.size
          writer.flush
          writer.full_flush
          io.to_slice.size.should eq(size)
          writer.write("!".to_slice)
          writer.flush
          io.to_slice.size.should be > size
          writer.close
          EncoderSamples.decode_with_zlib(format, io.to_slice).should eq("flush twice!".to_slice)
          EncoderSamples.decode_with_mica(format, io.to_slice).should eq("flush twice!".to_slice)
        end
      end
    end

    it_satisfies "DEFLATE-ENC-API-flush", "flushes a writer nothing was written to" do
      FORMATS.each do |format|
        io = IO::Memory.new
        writer = EncoderSamples.writer(format, io, 6)
        writer.flush
        io.to_slice[-5, 5].should eq(Bytes[0x00, 0x00, 0x00, 0xFF, 0xFF])
        writer.close
        EncoderSamples.decode_with_zlib(format, io.to_slice).should eq(Bytes.empty)
        EncoderSamples.decode_with_mica(format, io.to_slice).should eq(Bytes.empty)
      end
    end

    it_satisfies "DEFLATE-ENC-API-flush", "round-trips a stream flushed after every write, at every level" do
      input = EncoderSamples.text(20_000, 43)
      FORMATS.each do |format|
        0.upto(9) do |level|
          io = IO::Memory.new
          writer = EncoderSamples.writer(format, io, level)
          random = Random.new(level + 50)
          offset = 0
          while offset < input.size
            size = Math.min(random.rand(1..900), input.size - offset)
            writer.write(input[offset, size])
            offset += size
            random.rand(3) == 0 ? writer.full_flush : writer.flush
          end
          writer.close
          EncoderSamples.decode_with_zlib(format, io.to_slice).should eq(input)
          EncoderSamples.decode_with_mica(format, io.to_slice).should eq(input)
        end
      end
    end
  end

  describe "#full_flush" do
    it_satisfies "DEFLATE-ENC-API-full-flush", "starts the bytes after it from an empty history" do
      first = EncoderSamples.random_bytes(50_000, 47)
      # The second part repeats the end of the first, so after a sync flush
      # it is written as references into the first.
      second = first[30_000, 20_000]
      1.upto(9) do |level|
        io = IO::Memory.new
        writer = Mica::Deflate::Writer.new(io, level: level)
        writer.write(first)
        writer.full_flush
        boundary = io.to_slice.size
        io.to_slice[boundary - 4, 4].should eq(Bytes[0x00, 0x00, 0xFF, 0xFF])
        writer.write(second)
        writer.close
        whole = io.to_slice
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Raw, whole).should eq(EncoderSamples.join(first, second))
        # The rest is a stream of its own.
        rest = whole[boundary, whole.size - boundary]
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Raw, rest).should eq(second)
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Raw, rest).should eq(second)
        rest.should eq(Mica::Deflate.encode(second, level: level))

        # After a sync flush the rest refers back and cannot stand alone.
        io = IO::Memory.new
        writer = Mica::Deflate::Writer.new(io, level: level)
        writer.write(first)
        writer.flush
        boundary = io.to_slice.size
        writer.write(second)
        writer.close
        rest = io.to_slice[boundary, io.to_slice.size - boundary]
        DeflateOracle.decode(DeflateOracle::Format::Raw, rest).rejected?.should be_true
        rest.size.should be < 1_000
      end
    end
  end

  describe "#close" do
    it_satisfies "DEFLATE-ENC-API-close", "finishes the stream once and flushes the destination" do
      FORMATS.each do |format|
        io = RecordingIO.new
        writer = EncoderSamples.writer(format, io, 6)
        writer.closed?.should be_false
        writer.write("close me".to_slice)
        writer.close
        writer.closed?.should be_true
        io.closed?.should be_false
        io.flush_count.should eq(1)
        size = io.to_slice.size
        writer.close
        writer.flush
        writer.full_flush
        io.to_slice.size.should eq(size)
        EncoderSamples.decode_with_zlib(format, io.to_slice).should eq("close me".to_slice)
      end
    end

    it_satisfies "DEFLATE-ENC-API-close", "closes the destination only with sync_close" do
      io = IO::Memory.new
      writer = Mica::Gzip::Writer.new(io, sync_close: true)
      writer.sync_close?.should be_true
      writer.write("x".to_slice)
      writer.close
      io.closed?.should be_true
      io = IO::Memory.new
      Mica::Zlib::Writer.new(io).close
      io.closed?.should be_false
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Zlib, io.to_slice).should eq(Bytes.empty)
    end

    it_satisfies "DEFLATE-ENC-API-closed-writer", "raises IO::Error when written to after close, and when read from" do
      FORMATS.each do |format|
        writer = EncoderSamples.writer(format, IO::Memory.new, 6)
        expect_raises(IO::Error, "Can't read from") { writer.read(Bytes.new(4)) }
        expect_raises(IO::Error, "Can't read from") { writer.gets }
        writer.close
        expect_raises(IO::Error, "Closed stream") { writer.write("late".to_slice) }
        expect_raises(IO::Error, "Closed stream") { writer << "late" }
      end
    end
  end

  describe "the preset dictionary" do
    it_satisfies "DEFLATE-ENC-1950-2.2-dictionary", "writes the stream the one-shot encoder writes and round-trips with flushes" do
      dictionary = EncoderSamples.text(40_000, 53)
      input = EncoderSamples.join(dictionary[35_000, 4_000], EncoderSamples.text(50_000, 54), dictionary[20_000, 3_000])
      0.upto(9) do |level|
        io = IO::Memory.new
        writer = Mica::Zlib::Writer.new(io, level: level, dictionary: dictionary)
        writer.write(input)
        writer.close
        io.to_slice.should eq(Mica::Zlib.encode(input, level: level, dictionary: dictionary))
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Zlib, io.to_slice, dictionary).should eq(input)

        io = IO::Memory.new
        writer = Mica::Zlib::Writer.new(io, level: level, dictionary: dictionary)
        writer.flush
        writer.write(input[0, 5_000])
        writer.full_flush
        writer.write(input[5_000, input.size - 5_000])
        writer.close
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Zlib, io.to_slice, dictionary).should eq(input)
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Zlib, io.to_slice, dictionary).should eq(input)
      end
    end
  end

  describe "the gzip header" do
    it_satisfies "DEFLATE-ENC-1952-2.3-header-fields", "writes the header before the first byte of data" do
      header = Mica::Gzip::Header.new(modification_time: 86_400_u32, extra_flags: 0_u8, operating_system: 3_u8, is_text: false,
        extra_field: nil, file_name: "log.txt".to_slice, comment: nil)
      io = IO::Memory.new
      writer = Mica::Gzip::Writer.new(io, header: header)
      writer.flush
      io.to_slice[0, 18].should eq(Bytes[0x1F, 0x8B, 0x08, 0x08, 0x80, 0x51, 0x01, 0x00, 0x00, 0x03, 0x6C, 0x6F, 0x67, 0x2E,
        0x74, 0x78, 0x74, 0x00])
      writer << "line\n"
      writer.close
      reader = Mica::Gzip::Reader.new(IO::Memory.new(io.to_slice), limits: EncoderSamples::LIMITS, timeout: nil)
      reader.gets_to_end.should eq("line\n")
      reader.list_of_headers.first.file_name.should eq("log.txt".to_slice)
      io.to_slice.should_not eq(Mica::Gzip.encode("line\n".to_slice, header: header))
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Gzip, io.to_slice).should eq("line\n".to_slice)
    end
  end

  describe "memory" do
    it_satisfies "DEFLATE-ENC-MEMORY-bounded", "allocates under 384 KiB for a level 9 stream of any size" do
      sink = DiscardingIO.new
      piece = EncoderSamples.text(65_536, 59)
      before = allocated_bytes_so_far
      writer = Mica::Gzip::Writer.new(sink, level: 9)
      writer.write(piece[0, 100])
      writer.flush
      for_the_first_bytes = allocated_bytes_so_far - before
      40.times { writer.write(piece) }
      writer.close
      for_the_whole_stream = allocated_bytes_so_far - before
      # The window, the hash and chain tables and the symbol buffer
      # (328,704 bytes), a 16 KiB output buffer and the code builders.
      for_the_first_bytes.should be > 328_704
      for_the_first_bytes.should be < 384 * 1_024
      # 2.6 MB more input allocates nothing more.
      (for_the_whole_stream - for_the_first_bytes).should be < 4_096
    end
  end
end
