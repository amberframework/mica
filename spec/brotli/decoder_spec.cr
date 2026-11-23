require "./support/streams"

private def decode(bytes : Bytes, limits = BrotliStreams::LIMITS) : Bytes
  Mica::Brotli.decode(bytes, limits: limits, timeout: nil)
end

private def stream(window_bits = 16, &) : Bytes
  writer = BrotliStreams::BitWriter.new
  BrotliStreams.window(writer, window_bits)
  yield writer
  writer.to_slice
end

describe Mica::Brotli do
  describe ".decode" do
    it_satisfies "BROTLI-7932-9.1-window", "accepts every window size from 10 to 24 bits" do
      (10..24).each do |bits|
        encoded = stream(bits) { |writer| writer.bits(1, 1).bits(1, 1).align }
        decode(encoded).should eq(Bytes.empty)
      end
    end

    it_satisfies "BROTLI-7932-9.1-large-window", "rejects the large-window marker" do
      encoded = BrotliStreams::BitWriter.new.bits(1, 1).bits(0, 3).bits(1, 3).bits(0, 9).to_slice
      expect_raises(Mica::Brotli::MalformedStreamError, /Large-window/) { decode(encoded) }
    end

    it_satisfies "BROTLI-7932-9.2-uncompressed", "copies an uncompressed metablock" do
      decode(BrotliStreams.stored("hello, brotli".to_slice)).should eq("hello, brotli".to_slice)
    end

    it_satisfies "BROTLI-7932-9.2-metadata", "skips a metadata metablock, also as the last one" do
      encoded = stream do |writer|
        writer.bits(0, 1).bits(3, 2).bits(0, 1).bits(1, 2).bits(4, 8).align # 5 bytes of metadata
        writer.bytes("skip!".to_slice)
        writer.bits(1, 1).bits(0, 1).bits(3, 2).bits(0, 1).bits(0, 2).align # last, empty metadata
      end
      decode(encoded).should eq(Bytes.empty)
    end

    it_satisfies "BROTLI-7932-9.2-exuberant-nibble", "rejects a length whose last of 5 or 6 nibbles is zero" do
      encoded = stream do |writer|
        BrotliStreams.metablock_header(writer, 10, last: false, uncompressed: true, nibbles: 5)
      end
      expect_raises(Mica::Brotli::MalformedStreamError, /Exuberant/) { decode(encoded) }
    end

    it_satisfies "BROTLI-7932-9.2-padding", "rejects nonzero padding before an uncompressed metablock and after the last one" do
      encoded = stream do |writer|
        BrotliStreams.metablock_header(writer, 1, last: false, uncompressed: true)
        writer.bits(1, 1).align.bytes("x".to_slice).bits(3, 2).align
      end
      expect_raises(Mica::Brotli::MalformedStreamError, /padding/) { decode(encoded) }
      tail = stream { |writer| writer.bits(1, 1).bits(1, 1).bits(1, 1).align }
      expect_raises(Mica::Brotli::MalformedStreamError, /padding/) { decode(tail) }
    end

    it_satisfies "BROTLI-API-trailing", "rejects bytes after the end of the stream" do
      encoded = BrotliStreams.stored("x".to_slice)
      padded = Bytes.new(encoded.size + 1)
      padded.copy_from(encoded)
      expect_raises(Mica::Brotli::MalformedStreamError, /after the end/) { decode(padded) }
    end

    it_satisfies "BROTLI-API-truncation", "reports every proper prefix of a stream as truncated or malformed" do
      encoded = BrotliStreams.repeat_bomb(2, 5_000)
      (0...encoded.size).each do |size|
        expect_raises(Mica::Brotli::MalformedStreamError) { decode(encoded[0, size]) }
      end
      expect_raises(Mica::Brotli::TruncatedStreamError) { decode(encoded[0, encoded.size - 2]) }
    end

    it_satisfies "BROTLI-7932-4-distance-copy", "copies back references, overlapping ones included" do
      decode(BrotliStreams.repeat_bomb(3, 3_000)).should eq(Bytes.new(9_000, 'a'.ord.to_u8))
    end

    it_satisfies "BROTLI-7932-3.4-simple-duplicate", "rejects a simple prefix code that lists a symbol twice" do
      encoded = stream do |writer|
        BrotliStreams.metablock_header(writer, 4, last: true)
        3.times { writer.bits(0, 1) }
        writer.bits(0, 2).bits(0, 4).bits(0, 2).bits(0, 1).bits(0, 1)
        BrotliStreams.simple_code(writer, 8, ['a'.ord, 'a'.ord])
      end
      expect_raises(Mica::Brotli::MalformedStreamError, /repeats a symbol/) { decode(encoded) }
    end

    it_satisfies "BROTLI-7932-9.3-command-length", "rejects an insert that runs past its metablock" do
      encoded = stream do |writer|
        BrotliStreams.metablock_header(writer, 1, last: true)
        # insert code 2 (two literals) into a one-byte metablock
        BrotliStreams.trivial_compressed_header(writer, literal: 'a'.ord, command: BrotliStreams.command_symbol(2, 0),
          distance: 16)
        writer.align
      end
      expect_raises(Mica::Brotli::MalformedStreamError, /past the metablock/) { decode(encoded) }
    end

    it_satisfies "BROTLI-7932-4-short-distance", "rejects a short distance code that yields a distance below 1" do
      encoded = stream do |writer|
        BrotliStreams.metablock_header(writer, 10, last: true)
        # Two commands, each one literal and a 2-byte copy: the first at
        # distance code 16 (distance 1), the second at code 4 ("last
        # distance - 1", here 0).
        writer.bits(0, 1).bits(0, 1).bits(0, 1).bits(0, 2).bits(0, 4).bits(0, 2).bits(0, 1).bits(0, 1)
        BrotliStreams.simple_code(writer, 8, ['a'.ord])
        BrotliStreams.simple_code(writer, 10, [BrotliStreams.command_symbol(1, 0)])
        BrotliStreams.simple_code(writer, 6, [4, 16])
        writer.bits(1, 1).bits(0, 1) # code 16, extra bit 0: distance 1
        writer.bits(0, 1)            # code 4: distance 1 - 1 = 0
        writer.align
      end
      expect_raises(Mica::Brotli::MalformedStreamError, /below 1/) { decode(encoded) }
    end

    it_satisfies "BROTLI-7932-8-dictionary", "reads static dictionary words with their transforms" do
      # One metablock: a copy of length 4 at distance 1 is the first
      # 4-byte dictionary word ("time") with transform 0.
      encoded = stream do |writer|
        BrotliStreams.metablock_header(writer, 4, last: true)
        BrotliStreams.trivial_compressed_header(writer, literal: 'a'.ord, command: BrotliStreams.command_symbol(0, 2),
          distance: 16)
        writer.bits(0, 1).align
      end
      word = Mica::Brotli::Dictionary::DATA[0, 4]
      decode(encoded).should eq(word)
    end
  end
end
