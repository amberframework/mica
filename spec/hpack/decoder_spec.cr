require "./support"

private alias Header = Mica::HPACK::Header
private alias Limits = Mica::HPACK::DecodeLimits

private def integer_bytes(pattern : UInt8, prefix : Int32, value : Int64) : Bytes
  io = IO::Memory.new
  Mica::HPACK::PrefixInteger.encode(io, pattern, prefix, value)
  io.to_slice
end

# A literal with incremental indexing and a new name.
private def indexed_literal(name : String, value : String) : Bytes
  io = IO::Memory.new
  io.write_byte(0x40_u8)
  Mica::HPACK::PrefixInteger.encode(io, 0x00_u8, 7, name.bytesize.to_i64)
  io << name
  Mica::HPACK::PrefixInteger.encode(io, 0x00_u8, 7, value.bytesize.to_i64)
  io << value
  io.to_slice
end

describe Mica::HPACK::PrefixInteger do
  it_satisfies "HPACK-7541-5.1-integer", "encodes and decodes the C.1 examples" do
    integer_bytes(0x00_u8, 5, 10_i64).should eq Bytes[0x0a]
    integer_bytes(0x00_u8, 5, 1_337_i64).should eq Bytes[0x1f, 0x9a, 0x0a]
    integer_bytes(0x00_u8, 8, 42_i64).should eq Bytes[0x2a]
    Mica::HPACK::PrefixInteger.decode(Bytes[0x0a], 0, 5).should eq({10_i64, 1})
    Mica::HPACK::PrefixInteger.decode(Bytes[0x1f, 0x9a, 0x0a], 0, 5).should eq({1_337_i64, 3})
    Mica::HPACK::PrefixInteger.decode(Bytes[0x2a], 0, 8).should eq({42_i64, 1})
  end

  it_satisfies "HPACK-7541-5.1-integer", "round-trips values for every prefix from 5 to 8 bits" do
    random = Random.new(51)
    (5..8).each do |prefix|
      values = [0_i64, 1_i64, (1_i64 << prefix) - 2, (1_i64 << prefix) - 1, 1_i64 << prefix, 127_i64, 128_i64,
                16_383_i64, Mica::HPACK::MAX_INTEGER]
      200.times { values << random.rand(Mica::HPACK::MAX_INTEGER + 1) }
      values.each do |value|
        bytes = integer_bytes(0x00_u8, prefix, value)
        Mica::HPACK::PrefixInteger.decode(bytes, 0, prefix).should eq({value, bytes.size})
      end
    end
  end

  it_satisfies "HPACK-7541-5.1-integer-overflow", "rejects six continuation octets and values over 2^31-1" do
    # 2^31-1 itself needs five continuation octets with a 5-bit prefix.
    Mica::HPACK::PrefixInteger.decode(integer_bytes(0x00_u8, 5, Mica::HPACK::MAX_INTEGER), 0, 5)[0].should eq Mica::HPACK::MAX_INTEGER
    expect_raises(Mica::HPACK::IntegerOverflowError) do
      Mica::HPACK::PrefixInteger.decode(Bytes[0x1f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00], 0, 5)
    end
    expect_raises(Mica::HPACK::IntegerOverflowError) do
      Mica::HPACK::PrefixInteger.decode(Bytes[0x1f, 0xe1, 0xff, 0xff, 0xff, 0x07], 0, 5)
    end
    expect_raises(Mica::HPACK::IntegerOverflowError) do
      HPACKSpec.decoder.decode(Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f])
    end
  end
end

describe Mica::HPACK::Decoder do
  it_satisfies "HPACK-7541-2.3.1-static-table", "answers every static index" do
    decoder = HPACKSpec.decoder
    (1..61).each do |index|
      decoder.decode(integer_bytes(0x80_u8, 7, index.to_i64)).should eq [Mica::HPACK::StaticTable[index]]
    end
    Mica::HPACK::StaticTable[1].should eq Header.new(":authority", "")
    Mica::HPACK::StaticTable[61].should eq Header.new("www-authenticate", "")
  end

  it_satisfies "HPACK-7541-2.3.3-index-space", "puts the newest dynamic entry at 62 and rejects 0 and indices past the tables" do
    decoder = HPACKSpec.decoder
    decoder.decode(indexed_literal("a", "1"))
    decoder.decode(indexed_literal("b", "2"))
    decoder.decode(Bytes[0xbe, 0xbf]).should eq [Header.new("b", "2"), Header.new("a", "1")]
    expect_raises(Mica::HPACK::InvalidIndexError) { HPACKSpec.decoder.decode(Bytes[0x80]) }
    expect_raises(Mica::HPACK::InvalidIndexError) { HPACKSpec.decoder.decode(Bytes[0xbe]) }
    expect_raises(Mica::HPACK::InvalidIndexError) { HPACKSpec.decoder.decode(Bytes[0x7e, 0x01, 0x78]) }
  end

  it_satisfies "HPACK-7541-4.4-eviction-on-add", "evicts the oldest entries to fit, and empties the table for an oversized entry" do
    decoder = Mica::HPACK::Decoder.new(limits: Limits::PUBLIC_SERVER, max_table_size: 100)
    decoder.decode(indexed_literal("aaaa", "1111")) # 40 bytes
    decoder.decode(indexed_literal("bbbb", "2222")) # 80 bytes
    decoder.decode(indexed_literal("cccc", "3333")) # evicts aaaa
    decoder.table_length.should eq 2
    decoder.decode(Bytes[0xbf]).should eq [Header.new("bbbb", "2222")]
    decoder.decode(indexed_literal("x" * 40, "y" * 40)).should eq [Header.new("x" * 40, "y" * 40)]
    decoder.table_length.should eq 0
    decoder.table_size.should eq 0
  end

  it_satisfies "HPACK-7541-4.3-eviction-on-resize", "evicts the oldest entries when a size update lowers the table size" do
    decoder = HPACKSpec.decoder
    decoder.decode(indexed_literal("aaaa", "1111"))
    decoder.decode(indexed_literal("bbbb", "2222"))
    decoder.decode(Bytes[0x3f, 0x09, 0xbe]).should eq [Header.new("bbbb", "2222")] # size 40
    decoder.table_length.should eq 1
    decoder.table_capacity.should eq 40
  end

  it_satisfies "HPACK-7541-4.2-size-update-bound", "rejects a size update over the advertised maximum" do
    HPACKSpec.decoder.decode(integer_bytes(0x20_u8, 5, 4_096_i64)).should be_empty
    expect_raises(Mica::HPACK::TableSizeError) { HPACKSpec.decoder.decode(integer_bytes(0x20_u8, 5, 4_097_i64)) }
  end

  it_satisfies "HPACK-7541-6.3-size-update-position", "accepts size updates only before the first field" do
    HPACKSpec.decoder.decode(Bytes[0x20, 0x3f, 0xe1, 0x1f, 0x82]).should eq [Header.new(":method", "GET")]
    expect_raises(Mica::HPACK::TableSizeError) { HPACKSpec.decoder.decode(Bytes[0x82, 0x20]) }
  end

  it_satisfies "HPACK-7541-4.2-size-update-required", "requires a size update after the advertised maximum drops below the table size" do
    decoder = HPACKSpec.decoder
    decoder.max_table_size = 1_024
    expect_raises(Mica::HPACK::TableSizeError) { decoder.decode(Bytes[0x82]) }
    decoder = HPACKSpec.decoder
    decoder.max_table_size = 1_024
    decoder.decode(Bytes[0x3f, 0xe1, 0x07, 0x82]).should eq [Header.new(":method", "GET")]
    decoder.table_capacity.should eq 1_024
    decoder.max_table_size = 2_048 # raising it needs no update
    decoder.decode(Bytes[0x82]).size.should eq 1
    expect_raises(ArgumentError) { decoder.max_table_size = 4_097 }
  end

  it_satisfies "HPACK-7541-5.2-string-literal", "decodes raw and Huffman strings" do
    HPACKSpec.decoder.decode(HPACKSpec.hex("418cf1e3c2e5f23a6ba0ab90f4ff")).should eq [Header.new(":authority", "www.example.com")]
    HPACKSpec.decoder.decode(HPACKSpec.hex("410f7777772e6578616d706c652e636f6d")).should eq [Header.new(":authority", "www.example.com")]
  end

  it_satisfies "HPACK-API-truncated", "raises TruncatedBlockError for a block cut inside an integer or a string" do
    block = HPACKSpec.hex("400a637573746f6d2d6b65790d637573746f6d2d686561646572")
    (1...block.size).each do |cut|
      expect_raises(Mica::HPACK::TruncatedBlockError) { HPACKSpec.decoder.decode(block[0, cut]) }
    end
    expect_raises(Mica::HPACK::TruncatedBlockError) { HPACKSpec.decoder.decode(Bytes[0xff]) }
    expect_raises(Mica::HPACK::TruncatedBlockError) { HPACKSpec.decoder.decode(Bytes[0x3f, 0x80]) }
  end

  it_satisfies "HPACK-API-failed-decoder", "refuses blocks after a decoding error" do
    decoder = HPACKSpec.decoder
    expect_raises(Mica::HPACK::InvalidIndexError) { decoder.decode(Bytes[0x80]) }
    expect_raises(Mica::HPACK::DecodingError, /earlier block/) { decoder.decode(Bytes[0x82]) }
  end

  it_satisfies "HPACK-LIMIT-header-list", "stops an HPACK bomb at max_header_list_bytes and keeps the table usable" do
    limits = Limits.custom(max_header_list_bytes: 16_384)
    decoder = HPACKSpec.decoder(limits)
    # One 4,000-byte entry, then 10,000 one-byte references to it: about
    # 40 MB of headers from a 10 KB block.
    io = IO::Memory.new
    io.write(indexed_literal("x", "y" * 4_000))
    10_000.times { io.write_byte(0xbe_u8) }
    bomb = io.to_slice
    yielded = 0_i64
    before = allocated_bytes_so_far
    error = expect_raises(Mica::HPACK::DecodeLimitError) do
      decoder.decode(bomb) { |header| yielded += header.size }
    end
    (allocated_bytes_so_far - before).should be < 1_048_576
    error.limit.should eq "max_header_list_bytes"
    error.table_intact?.should be_true
    yielded.should be <= 16_384
    decoder.decode(Bytes[0xbe]).should eq [Header.new("x", "y" * 4_000)]
  end

  it_satisfies "HPACK-LIMIT-header-block", "refuses a block over max_header_block_bytes before reading it" do
    decoder = HPACKSpec.decoder(Limits.custom(max_header_block_bytes: 100))
    error = expect_raises(Mica::HPACK::DecodeLimitError) { decoder.decode(Bytes.new(101, 0x82_u8)) }
    error.limit.should eq "max_header_block_bytes"
    error.table_intact?.should be_false
    # The block was not read, so the table may have missed updates.
    expect_raises(Mica::HPACK::DecodingError, /earlier block/) { decoder.decode(Bytes[0x82]) }
    HPACKSpec.decoder(Limits.custom(max_header_block_bytes: 100)).decode(Bytes.new(100, 0x82_u8)).size.should eq 100
  end

  it_satisfies "HPACK-LIMIT-work", "charges decoding to the work budget" do
    limits = Limits.custom(max_header_list_bytes: 1 << 30, work_per_unit: 1_i64, base_work: 100_i64)
    expect_raises(Mica::WorkBudgetExceededError) { HPACKSpec.decoder(limits).decode(Bytes.new(1_000, 0xbd_u8)) }
    HPACKSpec.decoder(Limits::PUBLIC_SERVER).decode(Bytes.new(100, 0x82_u8)).size.should eq 100
  end

  it "rejects invalid limits" do
    expect_raises(ArgumentError) { Limits.custom(max_header_list_bytes: -1) }
    Limits::INTERNAL_SERVER.max_header_list_bytes.should eq 65_536
    Limits::CLIENT.max_header_block_bytes.should eq 131_072
  end
end

describe Mica::HPACK::Encoder do
  it_satisfies "HPACK-7541-2.3.1-static-table", "refers to static entries by full match and by name" do
    encoder = Mica::HPACK::Encoder.new(huffman: false)
    encoder.encode([Header.new(":method", "GET")]).should eq Bytes[0x82]
    encoder.encode([Header.new(":method", "PUT")]).should eq Bytes[0x42, 0x03, 'P'.ord, 'U'.ord, 'T'.ord]
  end

  it_satisfies "HPACK-7541-6.2.3-never-indexed", "sends credentials, cookies and marked fields as never-indexed literals" do
    encoder = Mica::HPACK::Encoder.new(huffman: false)
    decoder = HPACKSpec.decoder
    {"cookie", "set-cookie", "authorization", "proxy-authorization"}.each do |name|
      2.times do
        block = encoder.encode([Header.new(name, "secret")])
        (block[0] & 0xf0).should eq 0x10
        decoder.decode(block).should eq [Header.new(name, "secret", never_indexed: true)]
      end
    end
    block = encoder.encode([Header.new("x-token", "secret", never_indexed: true)])
    block[0].should eq 0x10
    encoder.table_size.should eq 0
    decoder.table_size.should eq 0
  end

  it_satisfies "HPACK-7541-4.2-size-update-required", "starts the next block with the smallest size and then the final size" do
    encoder = Mica::HPACK::Encoder.new(huffman: false)
    encoder.max_table_size = 0
    encoder.max_table_size = 2_048
    block = encoder.encode([Header.new(":method", "GET")])
    block.should eq Bytes[0x20, 0x3f, 0xe1, 0x0f, 0x82]
    encoder.encode([Header.new(":method", "GET")]).should eq Bytes[0x82]
  end

  it_satisfies "HPACK-ENCODER-DETERMINISTIC", "gives the same bytes for the same lists" do
    random = Random.new(9)
    lists = Array.new(200) { HPACKSpec.random_list(random) }
    first = Mica::HPACK::Encoder.new
    second = Mica::HPACK::Encoder.new
    lists.each { |list| first.encode(list).should eq second.encode(list) }
  end

  it_satisfies "HPACK-ENCODER-ROUND-TRIP", "encodes random lists, with table size changes, that decode to the same lists" do
    random = Random.new(2_2)
    3.times do |huffman_round|
      encoder = Mica::HPACK::Encoder.new(huffman: huffman_round != 0)
      decoder = HPACKSpec.decoder(HPACKSpec::CORPUS_LIMITS)
      2_000.times do
        if random.rand(50) == 0
          size = random.rand(0..4_096)
          encoder.max_table_size = size
          decoder.max_table_size = size
        end
        list = HPACKSpec.random_list(random)
        decoded = decoder.decode(encoder.encode(list))
        HPACKSpec.fields(decoded).should eq HPACKSpec.fields(list)
        decoder.table_size.should eq encoder.table_size
      end
    end
  end
end
