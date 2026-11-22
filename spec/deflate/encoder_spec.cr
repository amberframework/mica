require "./support/encoder_samples"

# Specs for the one-shot encoders, `Mica::Deflate.encode`,
# `Mica::Zlib.encode` and `Mica::Gzip.encode` (milestone Z2): every level
# round-trips through Mica's decoder and through the system zlib, and the
# streams have the shape RFC 1950, 1951 and 1952 give them. Requirement
# catalog: spec/requirements/deflate_encoder.tsv. The streaming writers
# are in writer_spec.cr.

private FORMATS = [DeflateOracle::Format::Raw, DeflateOracle::Format::Zlib, DeflateOracle::Format::Gzip]

# The sum of 2^-length over a code's symbols, in units of 2^-15: 32,768
# for a complete code.
private def kraft_sum(lengths : UInt8*, count : Int32) : Int32
  sum = 0
  count.times { |symbol| sum += 32_768 >> lengths[symbol] if lengths[symbol] != 0 }
  sum
end

describe "Mica::Deflate encoders, one-shot" do
  describe ".encode" do
    EncoderSamples.each_named_input do |name, input|
      it_satisfies({"DEFLATE-ENC-ROUNDTRIP-mica", "DEFLATE-ENC-ROUNDTRIP-zlib", "DEFLATE-ENC-ROUNDTRIP-edge-inputs"},
        "round-trips #{name} (#{input.size} bytes) at every level, in every container, through Mica and zlib") do
        FORMATS.each do |format|
          0.upto(9) do |level|
            stream = EncoderSamples.encode(format, input, level)
            EncoderSamples.decode_with_mica(format, stream).should eq(input)
            EncoderSamples.decode_with_zlib(format, stream).should eq(input)
          end
        end
      end
    end

    it_satisfies "DEFLATE-ENC-API-deterministic", "gives the same bytes for the same input and level" do
      input = EncoderSamples.text(50_000, 3)
      FORMATS.each do |format|
        {0, 1, 6, 9}.each do |level|
          EncoderSamples.encode(format, input, level).should eq(EncoderSamples.encode(format, input.dup, level))
        end
      end
    end

    it_satisfies "DEFLATE-ENC-API-levels", "raises ArgumentError for a level outside 0 to 9" do
      input = "level".to_slice
      {-1, 10, 100}.each do |level|
        expect_raises(ArgumentError, "Invalid compression level #{level}") { Mica::Deflate.encode(input, level: level) }
        expect_raises(ArgumentError, "Invalid compression level #{level}") { Mica::Zlib.encode(input, level: level) }
        expect_raises(ArgumentError, "Invalid compression level #{level}") { Mica::Gzip.encode(input, level: level) }
      end
    end

    it "uses level 6 by default" do
      input = EncoderSamples.text(30_000, 5)
      Mica::Deflate.encode(input).should eq(Mica::Deflate.encode(input, level: 6))
      Mica::Zlib.encode(input).should eq(Mica::Zlib.encode(input, level: 6))
      Mica::Gzip.encode(input).should eq(Mica::Gzip.encode(input, level: 6))
    end
  end

  describe "the blocks (RFC 1951)" do
    it_satisfies "DEFLATE-ENC-1951-3.2.3-final-block", "ends every stream with one final block, also for an empty input" do
      Mica::Deflate.encode(Bytes.empty, level: 6).should eq(Bytes[0x03, 0x00])
      Mica::Deflate.encode(Bytes.empty, level: 0).should eq(Bytes[0x01, 0x00, 0x00, 0xFF, 0xFF])
      {0, 1, 6, 9}.each do |level|
        list_of_blocks = DeflateTokens.read(Mica::Deflate.encode(EncoderSamples.text(200_000, 2), level: level))
        list_of_blocks.count(&.is_final).should eq(1)
        list_of_blocks.last.is_final.should be_true
        list_of_blocks.size.should be > 1
      end
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.4-stored", "writes only stored blocks of at most 65,535 bytes at level 0" do
      input = EncoderSamples.text(150_000)
      stream = Mica::Deflate.encode(input, level: 0)
      list_of_blocks = DeflateTokens.read(stream)
      list_of_blocks.map(&.type).uniq!.should eq([0])
      list_of_blocks.map(&.stored_bytes).should eq([65_535, 65_535, 18_930])
      stream.size.should eq(input.size + 3 * 5)
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.4-stored", "stores incompressible data at every level, growing it by at most 5 bytes per block" do
      input = EncoderSamples.random_bytes(100_000, 9)
      1.upto(9) do |level|
        stream = Mica::Deflate.encode(input, level: level)
        list_of_blocks = DeflateTokens.read(stream)
        list_of_blocks.map(&.type).uniq!.should eq([0])
        stream.size.should be <= input.size + 5 * list_of_blocks.size
      end
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.5-match-limits", "uses matches of length 258 at distance 32,768" do
      input = EncoderSamples.repeat_at_the_window_edge
      1.upto(9) do |level|
        stream = Mica::Deflate.encode(input, level: level)
        list_of_matches = DeflateTokens.read(stream).flat_map(&.list_of_matches)
        list_of_matches.count { |match| match.length == 258 && match.distance == 32_768 }.should be >= 120
        list_of_matches.max_of(&.length).should eq(258)
        list_of_matches.max_of(&.distance).should eq(32_768)
        list_of_matches.min_of(&.length).should be >= 3
        # The second copy costs a few bytes per 258.
        stream.size.should be < 32_769 + 1_000
      end
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.5-match-limits", "writes only lengths 3 to 258 and distances 1 to 32,768" do
      {EncoderSamples.text(90_000, 4), EncoderSamples.runs(90_000)}.each do |input|
        {1, 4, 9}.each do |level|
          list_of_matches = DeflateTokens.read(Mica::Deflate.encode(input, level: level)).flat_map(&.list_of_matches)
          list_of_matches.size.should be > 100
          list_of_matches.each do |match|
            (3..258).should contain(match.length)
            (1..32_768).should contain(match.distance)
          end
        end
      end
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.3-smallest-block", "picks a fixed block for a short text and a dynamic block for a long one" do
      DeflateTokens.read(Mica::Deflate.encode("abcabcabc".to_slice, level: 6)).map(&.type).should eq([1])
      DeflateTokens.read(Mica::Deflate.encode(EncoderSamples.text(20_000), level: 6)).map(&.type).should eq([2])
      DeflateTokens.read(Mica::Deflate.encode(EncoderSamples.random_bytes(2_000), level: 6)).map(&.type).should eq([0])
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.3-smallest-block", "starts a new block every 16,383 symbols" do
      # Random bytes drawn from 16 values: all literals, and far from stored.
      random = Random.new(11)
      input = Bytes.new(100_000) { (random.rand(16) * 16 + random.rand(2)).to_u8 }
      list_of_blocks = DeflateTokens.read(Mica::Deflate.encode(input, level: 1))
      list_of_blocks.each { |block| (block.literal_count + block.list_of_matches.size).should be <= 16_383 }
      list_of_blocks.size.should be >= 2
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.7-code-limits", "limits a code to 15 bits when the frequencies call for a longer one" do
      # Fibonacci frequencies make the unlimited Huffman code as deep as it gets.
      builder = Mica::Deflate::HuffmanCodeBuilder.new(286, 15)
      first = 1
      second = 1
      24.times do |symbol|
        builder.frequencies[symbol * 7] = first
        first, second = second, first + second
      end
      builder.build
      lengths = builder.lengths
      (0...286).max_of { |symbol| lengths[symbol] }.should eq(15)
      kraft_sum(lengths, 286).should eq(32_768)
      (0...286).count { |symbol| lengths[symbol] != 0 }.should eq(24)
      # The most frequent symbol has the shortest code.
      lengths[23 * 7].should eq((0...286).compact_map { |symbol| lengths[symbol] if lengths[symbol] != 0 }.min)
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.7-code-limits", "limits the code-length code to 7 bits and keeps codes complete" do
      builder = Mica::Deflate::HuffmanCodeBuilder.new(19, 7)
      first = 1
      second = 1
      19.times do |symbol|
        builder.frequencies[symbol] = first
        first, second = second, first + second
      end
      builder.build
      (0...19).max_of { |symbol| builder.lengths[symbol] }.should eq(7)
      kraft_sum(builder.lengths, 19).should eq(32_768)
      # A code with one used symbol gains a second so that it is complete.
      builder.reset
      builder.frequencies[5] = 9
      builder.build
      kraft_sum(builder.lengths, 19).should eq(32_768)
    end

    it_satisfies "DEFLATE-ENC-1951-3.2.7-code-limits", "round-trips inputs with heavily skewed byte frequencies" do
      random = Random.new(21)
      list_of_bytes = [] of UInt8
      count = 1
      next_count = 1
      22.times do |value|
        count.times { list_of_bytes << (value * 11).to_u8 }
        count, next_count = next_count, count + next_count
      end
      input = Slice.new(list_of_bytes.size) { |index| list_of_bytes[index] }
      input.shuffle!(random)
      {1, 6, 9}.each do |level|
        stream = Mica::Deflate.encode(input, level: level)
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Raw, stream).should eq(input)
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Raw, stream).should eq(input)
      end
    end
  end

  describe "the zlib container (RFC 1950)" do
    it_satisfies "DEFLATE-ENC-1950-2.2-header", "writes CM 8, CINFO 7, zlib's FLEVEL for the level and a valid FCHECK" do
      input = EncoderSamples.text(5_000)
      expected_flevel = {0, 0, 1, 1, 1, 1, 2, 3, 3, 3}
      0.upto(9) do |level|
        stream = Mica::Zlib.encode(input, level: level)
        stream[0].should eq(0x78)
        (stream[1] >> 6).should eq(expected_flevel[level])
        (stream[1] & 0x20).should eq(0)
        ((stream[0].to_i32 << 8) | stream[1]).remainder(31).should eq(0)
        stream[0, 2].should eq(DeflateOracle.compress(input, DeflateOracle::Format::Zlib, level: level)[0, 2])
      end
    end

    it_satisfies "DEFLATE-ENC-1950-2.2-adler32", "ends with the Adler-32 of the input, big-endian" do
      input = EncoderSamples.text(70_000, 8)
      stream = Mica::Zlib.encode(input, level: 6)
      adler = DeflateOracle.adler32(input)
      stream[stream.size - 4, 4].should eq(Bytes[(adler >> 24).to_u8!, (adler >> 16).to_u8!, (adler >> 8).to_u8!, adler.to_u8!])
      Mica::Zlib.encode(Bytes.empty)[-4, 4].should eq(Bytes[0, 0, 0, 1])
    end

    it_satisfies "DEFLATE-ENC-1950-2.2-dictionary", "sets FDICT, writes the dictionary's Adler-32 and refers to the dictionary" do
      dictionary = EncoderSamples.random_bytes(4_000, 31)
      input = dictionary[500, 3_000]
      1.upto(9) do |level|
        stream = Mica::Zlib.encode(input, level: level, dictionary: dictionary)
        (stream[1] & 0x20).should eq(0x20)
        ((stream[0].to_i32 << 8) | stream[1]).remainder(31).should eq(0)
        adler = DeflateOracle.adler32(dictionary)
        stream[2, 4].should eq(Bytes[(adler >> 24).to_u8!, (adler >> 16).to_u8!, (adler >> 8).to_u8!, adler.to_u8!])
        # The whole input is one stretch of the dictionary.
        stream.size.should be < 80
        stream.size.should be < Mica::Zlib.encode(input, level: level).size // 10
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Zlib, stream, dictionary).should eq(input)
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Zlib, stream, dictionary).should eq(input)
      end
    end

    it_satisfies "DEFLATE-ENC-1950-2.2-dictionary", "needs the same dictionary to decode" do
      dictionary = "preset dictionary words".to_slice
      stream = Mica::Zlib.encode("dictionary words preset".to_slice, dictionary: dictionary)
      expect_raises(Mica::Deflate::MalformedStreamError) do
        Mica::Zlib.decode(stream, limits: EncoderSamples::LIMITS, timeout: nil)
      end
      expect_raises(Mica::Deflate::ChecksumError) do
        Mica::Zlib.decode(stream, limits: EncoderSamples::LIMITS, timeout: nil, dictionary: "another dictionary".to_slice)
      end
      DeflateOracle.decode(DeflateOracle::Format::Zlib, stream).rejection.should eq(DeflateOracle::Rejection::Dictionary)
    end

    it_satisfies "DEFLATE-ENC-1950-2.2-dictionary", "uses the last 32 KiB of a longer dictionary, at every level" do
      dictionary = EncoderSamples.random_bytes(50_000, 41)
      # The first stretch lies before the last 32 KiB; the second inside it.
      input = EncoderSamples.join(dictionary[1_000, 2_000], dictionary[40_000, 2_000])
      0.upto(9) do |level|
        stream = Mica::Zlib.encode(input, level: level, dictionary: dictionary)
        EncoderSamples.decode_with_mica(DeflateOracle::Format::Zlib, stream, dictionary).should eq(input)
        EncoderSamples.decode_with_zlib(DeflateOracle::Format::Zlib, stream, dictionary).should eq(input)
        next if level == 0
        stream.size.should be > 2_000
        stream.size.should be < 2_300
      end
    end

    it "accepts an empty dictionary and an input longer than the window after a dictionary" do
      empty = Bytes.empty
      input = EncoderSamples.text(100_000, 12)
      stream = Mica::Zlib.encode(input, dictionary: empty)
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Zlib, stream, empty).should eq(input)
      dictionary = EncoderSamples.text(20_000, 13)
      stream = Mica::Zlib.encode(input, level: 9, dictionary: dictionary)
      EncoderSamples.decode_with_mica(DeflateOracle::Format::Zlib, stream, dictionary).should eq(input)
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Zlib, stream, dictionary).should eq(input)
    end
  end

  describe "the gzip container (RFC 1952)" do
    it_satisfies "DEFLATE-ENC-1952-2.3-default-header", "writes MTIME 0, OS 255, no optional fields and zlib's XFL" do
      input = EncoderSamples.text(3_000)
      expected_extra_flags = {4, 4, 0, 0, 0, 0, 0, 0, 0, 2}
      0.upto(9) do |level|
        stream = Mica::Gzip.encode(input, level: level)
        stream[0, 10].should eq(Bytes[0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, expected_extra_flags[level], 0xFF])
        stream[8].should eq(DeflateOracle.compress(input, DeflateOracle::Format::Gzip, level: level)[8])
      end
    end

    it_satisfies "DEFLATE-ENC-1952-2.3-trailer", "ends with the CRC-32 and the size of the input, little-endian" do
      input = EncoderSamples.text(70_000, 6)
      stream = Mica::Gzip.encode(input, level: 6)
      crc = DeflateOracle.crc32(input)
      stream[stream.size - 8, 4].should eq(Bytes[crc.to_u8!, (crc >> 8).to_u8!, (crc >> 16).to_u8!, (crc >> 24).to_u8!])
      stream[stream.size - 4, 4].should eq(Bytes[0x70, 0x11, 0x01, 0x00])
      Mica::Gzip.encode(Bytes.empty)[-8, 8].should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0])
    end

    it_satisfies "DEFLATE-ENC-1952-2.3-header-fields", "writes a header's fields so that they read back unchanged" do
      input = EncoderSamples.text(10_000, 14)
      header = Mica::Gzip::Header.new(modification_time: 1_795_000_000_u32, extra_flags: 2_u8, operating_system: 3_u8,
        is_text: true, extra_field: Bytes[0x41, 0x70, 0x02, 0x00, 0x2A, 0x2B], file_name: "notes.txt".to_slice,
        comment: "written by Mica".to_slice)
      stream = Mica::Gzip.encode(input, level: 6, header: header)
      stream[0, 4].should eq(Bytes[0x1F, 0x8B, 0x08, 0x1D])
      IO::ByteFormat::LittleEndian.decode(UInt32, stream[4, 4]).should eq(1_795_000_000_u32)
      stream[8, 2].should eq(Bytes[0x02, 0x03])
      reader = Mica::Gzip::Reader.new(IO::Memory.new(stream), limits: EncoderSamples::LIMITS, timeout: nil)
      reader.getb_to_end.should eq(input)
      read_back = reader.list_of_headers.first
      read_back.modification_time.should eq(header.modification_time)
      read_back.extra_flags.should eq(header.extra_flags)
      read_back.operating_system.should eq(header.operating_system)
      read_back.is_text.should be_true
      read_back.extra_field.should eq(header.extra_field)
      read_back.file_name.should eq(header.file_name)
      read_back.comment.should eq(header.comment)
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Gzip, stream).should eq(input)
    end

    it_satisfies "DEFLATE-ENC-1952-2.3-header-fields", "writes only the fields a header has" do
      header = Mica::Gzip::Header.new(modification_time: 0_u32, extra_flags: 0_u8, operating_system: 255_u8, is_text: false,
        extra_field: nil, file_name: "a".to_slice, comment: nil)
      stream = Mica::Gzip.encode("x".to_slice, header: header)
      stream[0, 12].should eq(Bytes[0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0xFF, 0x61, 0x00])
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Gzip, stream).should eq("x".to_slice)
      empty_fields = Mica::Gzip::Header.new(modification_time: 0_u32, extra_flags: 0_u8, operating_system: 255_u8,
        is_text: false, extra_field: Bytes.empty, file_name: Bytes.empty, comment: Bytes.empty)
      stream = Mica::Gzip.encode("x".to_slice, header: empty_fields)
      stream[0, 14].should eq(Bytes[0x1F, 0x8B, 0x08, 0x1C, 0, 0, 0, 0, 0, 0xFF, 0x00, 0x00, 0x00, 0x00])
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Gzip, stream).should eq("x".to_slice)
    end

    it_satisfies "DEFLATE-ENC-1952-2.3-header-arguments", "raises ArgumentError for a field the format cannot carry" do
      plain = {modification_time: 0_u32, extra_flags: 0_u8, operating_system: 255_u8, is_text: false}
      with_zero_in_name = Mica::Gzip::Header.new(**plain, extra_field: nil, file_name: Bytes[0x61, 0x00, 0x62], comment: nil)
      with_zero_in_comment = Mica::Gzip::Header.new(**plain, extra_field: nil, file_name: nil, comment: Bytes[0x00])
      with_long_extra = Mica::Gzip::Header.new(**plain, extra_field: Bytes.new(65_536), file_name: nil, comment: nil)
      expect_raises(ArgumentError, "file name cannot contain a zero byte") do
        Mica::Gzip.encode("x".to_slice, header: with_zero_in_name)
      end
      expect_raises(ArgumentError, "comment cannot contain a zero byte") do
        Mica::Gzip.encode("x".to_slice, header: with_zero_in_comment)
      end
      expect_raises(ArgumentError, "at most 65,535 bytes") do
        Mica::Gzip::Writer.new(IO::Memory.new, header: with_long_extra)
      end
      longest_extra = Mica::Gzip::Header.new(**plain, extra_field: Bytes.new(65_535, 7_u8), file_name: nil, comment: nil)
      stream = Mica::Gzip.encode("x".to_slice, header: longest_extra)
      EncoderSamples.decode_with_zlib(DeflateOracle::Format::Gzip, stream).should eq("x".to_slice)
    end
  end

  describe "size and memory" do
    it_satisfies "DEFLATE-ENC-SIZE-tracks-zlib", "stays within 1% of zlib #{DeflateOracle.version} at levels 1 to 9" do
      list_of_inputs = [EncoderSamples.text(150_000, 17), EncoderSamples.runs(100_000),
                        File.open(File.join(__DIR__, "../../bench/deflate/corpus/http/html_64k.html"), &.getb_to_end),
                        File.open(File.join(__DIR__, "../../bench/deflate/corpus/http/json_64k.json"), &.getb_to_end)]
      1.upto(9) do |level|
        mica_bytes = 0
        zlib_bytes = 0
        list_of_inputs.each do |input|
          mica_bytes += Mica::Deflate.encode(input, level: level).size
          zlib_bytes += DeflateOracle.compress(input, level: level).size
        end
        (mica_bytes / zlib_bytes).should be <= 1.01
      end
    end

    it_satisfies "DEFLATE-ENC-MEMORY-bounded", "holds at most 384 KiB of tables for a stream at level 9" do
      deflater = Mica::Deflate::Deflater.new(Mica::Deflate::Format::Gzip, 9, IO::Memory.new)
      deflater.write(EncoderSamples.text(300_000, 19))
      deflater.table_bytes.should eq(262_144)
      deflater.table_bytes.should be <= 384 * 1_024
      deflater.release
      stored_only = Mica::Deflate::Deflater.new(Mica::Deflate::Format::Raw, 0, IO::Memory.new)
      stored_only.table_bytes.should eq(0)
      stored_only.release
    end
  end
end
