require "./support/bit_writer"

# Conformance specs for raw DEFLATE (RFC 1951) in Mica::Deflate: every
# vector is built bit by bit with the builders in support/bit_writer.cr.
# Each `it_inflates` / `it_refuses_to_inflate` / `it_decodes_vector` /
# `it_rejects_vector` example checks the one-shot decode and registers its
# vector, which streaming_spec.cr replays through the Reader.

# Returns *size* code lengths, zero except the symbols in *assigned*.
private def lengths(size : Int32, assigned : Hash(Int32, Int32)) : Array(Int32)
  list_of_lengths = Array.new(size, 0)
  assigned.each { |symbol, length| list_of_lengths[symbol] = length }
  list_of_lengths
end

# Returns code lengths that give each of *count* symbols (2 or more) a code
# and form a complete code: the shorter codes first.
private def complete_lengths(count : Int32) : Array(Int32)
  short = 0
  while (2 << short) <= count
    short += 1
  end
  count_of_short = (2 << short) - count
  Array.new(count) { |symbol| symbol < count_of_short ? short : short + 1 }
end

# Returns *size* code lengths that give the symbols of *list_of_symbols*
# the lengths 1, 2, ... n-1, n-1: a complete code whose longest codes are
# as long as the list allows (15 bits for 16 symbols).
private def ladder_lengths(size : Int32, list_of_symbols : Array(Int32)) : Array(Int32)
  list_of_lengths = Array.new(size, 0)
  list_of_symbols.each_with_index do |symbol, index|
    list_of_lengths[symbol] = Math.min(index + 1, list_of_symbols.size - 1)
  end
  list_of_lengths
end

# A complete literal/length code over "abcd", end of block and the length
# symbols 257, 258 and 285 (eight codes of 3 bits).
private ABCD_LITERAL_LENGTHS = lengths(286, {97 => 3, 98 => 3, 99 => 3, 100 => 3, 256 => 3, 257 => 3, 258 => 3, 285 => 3})
# A complete distance code over distance symbols 0 to 3.
private FOUR_DISTANCE_LENGTHS = [2, 2, 2, 2]
# A literal/length code with two 1-bit codes: literal 0 ("0") and end of
# block ("1").
private ZERO_AND_END_LENGTHS = lengths(257, {0 => 1, 256 => 1})

private def sample(size : Int32, seed : UInt32 = 1_u32) : Bytes
  DeflateConformance.sample_bytes(size, seed)
end

describe Mica::Deflate do
  describe "block headers (RFC 1951 3.2.3)" do
    it_inflates({"DEFLATE-1951-3.2.3-block-header", "DEFLATE-1951-3.2.6-fixed-codes"}, "decodes an empty final fixed block") do |deflate|
      deflate.fixed(final: true) { }
    end

    it_inflates "DEFLATE-1951-3.2.3-block-header", "reads block headers at every bit position" do |deflate|
      # An empty fixed block is 10 bits, so nine of them start at bit
      # offsets 0, 2, 4, 6, 0, 2, ...; the literal blocks shift by one bit.
      9.times { deflate.fixed { } }
      7.times { deflate.fixed(&.literal('x'.ord)) }
      deflate.stored("stored".to_slice)
      5.times { deflate.fixed(&.literal('y'.ord)) }
      deflate.fixed(final: true) { }
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.3-reserved-block-type", "rejects block type 3 in a final block", :malformed do |deflate|
      deflate.block_header(3, final: true)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.3-reserved-block-type", "rejects block type 3 in a non-final block", :malformed do |deflate|
      deflate.block_header(3, final: false)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.3-reserved-block-type", "rejects block type 3 after valid blocks", :malformed do |deflate|
      deflate.fixed(&.literals("abc"))
      deflate.stored("def".to_slice)
      deflate.block_header(3, final: true)
      deflate.bit_writer.align.bytes(Bytes[0, 0, 0xff, 0xff])
    end

    it_inflates "DEFLATE-1951-3.2.3-block-sequence", "concatenates stored, fixed and dynamic blocks in every order" do |deflate|
      deflate.stored("stored one ".to_slice)
      deflate.fixed(&.literals("fixed one "))
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, &.literals("abcd"))
      deflate.fixed(&.literals(" fixed two "))
      deflate.stored("stored two ".to_slice)
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, &.literals("dcba"))
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, &.literals("aa"))
      deflate.stored(" stored three".to_slice)
      deflate.stored(Bytes.empty)
      deflate.fixed(final: true, &.literals(" end"))
    end

    it_inflates "DEFLATE-1951-3.2.3-final-block", "stops at the final block and ignores the padding bits after it" do |deflate|
      deflate.fixed(final: true, &.literals("pad"))
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.3-final-block", "reports a stream of non-final stored blocks as truncated", :truncated do |deflate|
      deflate.stored("abc".to_slice)
      deflate.stored("def".to_slice)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.3-final-block", "reports a stream of non-final fixed blocks as truncated", :truncated do |deflate|
      deflate.fixed(&.literals("abc"))
      deflate.fixed(&.literals("def"))
      # The four zero bits left in the last byte start a stored block header.
    end

    it_rejects_vector "DEFLATE-API-truncation", "reports empty input as truncated", :raw, Bytes.empty, :truncated

    it_rejects_vector "DEFLATE-API-trailing-data", "rejects one byte after the final block", :raw,
      DeflateConformance.join(DeflateConformance.deflate(&.fixed(final: true, &.literals("abc"))).to_slice, Bytes[0]), :malformed

    it_rejects_vector "DEFLATE-API-trailing-data", "rejects a second stream after the final block", :raw,
      DeflateConformance.join(
        DeflateConformance.deflate(&.stored("abc".to_slice, final: true)).to_slice,
        DeflateConformance.deflate(&.stored("def".to_slice, final: true)).to_slice), :malformed

    it_inflates "DEFLATE-API-trailing-data", "ignores a block header in the padding bits after the final block" do |deflate|
      # The final block ends 2 bits into its last byte; the header of a
      # dynamic block in the 6 bits left is padding.
      deflate.fixed(final: true, &.literal('a'.ord))
      deflate.block_header(2, final: false)
      deflate.bit_writer.bits(0b101, 3)
    end
  end

  describe "stored blocks (RFC 1951 3.2.4)" do
    it_inflates "DEFLATE-1951-3.2.4-stored-data", "decodes an empty stored block" do |deflate|
      deflate.stored(Bytes.empty, final: true)
    end

    it_inflates "DEFLATE-1951-3.2.4-stored-data", "decodes a one-byte stored block" do |deflate|
      deflate.stored(Bytes[0xa5], final: true)
    end

    it_inflates({"DEFLATE-1951-3.2.4-stored-data", "DEFLATE-1951-3.1.1-bit-order"}, "reads LEN and NLEN least significant byte first") do |deflate|
      # 258 bytes: LEN is 02 01, NLEN is fd fe.
      deflate.stored(sample(258), final: true)
    end

    it_inflates "DEFLATE-1951-3.2.4-stored-data", "decodes a stored block of 65,535 bytes" do |deflate|
      deflate.stored(sample(65_535), final: true)
    end

    it_inflates "DEFLATE-1951-3.2.4-stored-data", "decodes stored blocks that end on, before and after 4,096-byte buffer edges" do |deflate|
      [4_091, 4_096, 4_097, 1, 0, 8_192, 65_535, 3, 4_095].each_with_index do |size, index|
        deflate.stored(sample(size, index.to_u32 + 7))
      end
      deflate.stored(Bytes.empty, final: true)
    end

    it_inflates "DEFLATE-1951-3.2.4-stored-data", "decodes empty stored blocks between other blocks (the sync flush marker)" do |deflate|
      deflate.fixed(&.literals("before"))
      deflate.stored(Bytes.empty)
      deflate.stored(Bytes.empty)
      deflate.fixed(final: true, &.literals("after"))
    end

    it_inflates "DEFLATE-1951-3.2.4-stored-alignment", "ignores padding bits of one before LEN" do |deflate|
      deflate.stored("ones".to_slice, final: true, padding_bit: 1)
    end

    it_inflates "DEFLATE-1951-3.2.4-stored-alignment", "skips to the byte boundary from every bit offset" do |deflate|
      # Each empty fixed block moves the next header 10 bits on, so the
      # stored blocks skip 5, 3, 1, 7, 5, ... bits (alternately ones).
      8.times do |index|
        deflate.fixed { }
        deflate.stored(Bytes[index.to_u8], padding_bit: index & 1)
        (index % 3).times { deflate.fixed(&.literal('z'.ord)) }
      end
      deflate.stored("end".to_slice, final: true)
    end

    it_inflates "DEFLATE-1951-3.2.4-stored-alignment", "skips no bits when the header ends on a byte boundary" do |deflate|
      # 3 header bits, a 9-bit literal and a 7-bit end of block: 19 bits;
      # then a 10-bit empty block and the 3-bit stored header end at bit 32.
      deflate.fixed(&.literal(200)).fixed { }
      deflate.stored("aligned".to_slice, final: true)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.4-stored-length", "rejects NLEN equal to LEN", :malformed do |deflate|
      deflate.stored("abc".to_slice, final: true, declared_complement: 3)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.4-stored-length", "rejects NLEN of zero for an empty block", :malformed do |deflate|
      deflate.stored(Bytes.empty, final: true, declared_complement: 0)
    end

    16.times do |bit|
      it_refuses_to_inflate "DEFLATE-1951-3.2.4-stored-length", "rejects NLEN with bit #{bit} flipped", :malformed do |deflate|
        deflate.stored("abc".to_slice, final: true, declared_complement: (3 ^ 0xFFFF) ^ (1 << bit))
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.4-stored-length", "rejects a wrong NLEN in a later block", :malformed do |deflate|
      deflate.stored("abc".to_slice)
      deflate.stored("def".to_slice, final: true, declared_complement: 0xFFFF)
    end

    stored = DeflateConformance.deflate(&.stored("abcdef".to_slice, final: true)).to_slice
    {1 => "after the block header", 2 => "inside LEN", 3 => "after LEN", 4 => "inside NLEN", 5 => "before the data", 8 => "inside the data", 10 => "one byte before the end"}.each do |size, place|
      it_rejects_vector "DEFLATE-API-truncation", "reports a stored block cut #{place} as truncated", :raw, stored[0, size], :truncated
    end

    it_refuses_to_inflate "DEFLATE-API-truncation", "reports a stored block shorter than its LEN as truncated", :truncated do |deflate|
      deflate.stored(sample(1_000), final: true, declared_length: 65_535)
    end

    it_satisfies "DEFLATE-API-truncation", "reports every proper prefix of a stream of stored blocks as truncated" do
      stream = DeflateConformance.deflate do |deflate|
        deflate.stored("ab".to_slice).fixed { }
        deflate.stored(Bytes.empty).stored("cde".to_slice, final: true)
      end
      DeflateConformance.check_every_prefix_is_truncated(:raw, stream.to_slice)
    end
  end

  describe "fixed codes (RFC 1951 3.2.6)" do
    it_inflates({"DEFLATE-1951-3.2.5-literals", "DEFLATE-1951-3.2.6-fixed-codes"}, "decodes every literal byte with the 8-bit and 9-bit fixed codes") do |deflate|
      deflate.fixed(final: true) do |block|
        256.times { |byte| block.literal(byte) }
        255.downto(0) { |byte| block.literal(byte) }
      end
    end

    it_inflates "DEFLATE-1951-3.2.5-end-of-block", "ends each block at symbol 256 and starts the next one" do |deflate|
      deflate.fixed(&.literals("one"))
      deflate.fixed { }
      deflate.fixed(&.literals("two"))
      deflate.fixed(final: true) { }
    end

    257.upto(285) do |symbol|
      extra_bits = DeflateConformance::LENGTH_EXTRA_BITS[symbol - 257]
      base = DeflateConformance::LENGTH_BASE[symbol - 257]
      # Symbol 284 with all five extra bits set has its own example below.
      largest = symbol == 284 ? 30 : (1 << extra_bits) - 1
      it_inflates({"DEFLATE-1951-3.2.5-length-codes", "DEFLATE-1951-3.2.6-fixed-codes"}, "decodes length symbol #{symbol} as lengths #{base} to #{base + largest}") do |deflate|
        deflate.fixed(final: true) do |block|
          block.literals("ab")
          block.match_symbols(symbol, 0, 1, 0)
          block.literal('c'.ord)
          block.match_symbols(symbol, largest, 2, 0)
          block.literal('d'.ord)
          # 0b01011 reads differently in the two bit orders.
          block.match_symbols(symbol, 0b01011 & largest, 3, 0)
        end
      end
    end

    it_inflates "DEFLATE-1951-3.2.5-length-284-extra-31", "decodes length symbol 284 with extra bits 31 as length 258" do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("ab")
        block.match_symbols(284, 31, 1, 0)
        block.literal('c'.ord)
      end
    end

    it_inflates "DEFLATE-1951-3.2.5-length-284-extra-31", "gives symbol 284 with extra bits 31 the same output as symbol 285" do |deflate|
      deflate.fixed do |block|
        block.literals("xyz")
        block.match_symbols(284, 31, 2, 0)
      end
      deflate.fixed(final: true, &.match_symbols(285, 0, 2, 0))
    end

    0.upto(29) do |symbol|
      extra_bits = DeflateConformance::DISTANCE_EXTRA_BITS[symbol]
      base = DeflateConformance::DISTANCE_BASE[symbol]
      largest = (1 << extra_bits) - 1
      it_inflates({"DEFLATE-1951-3.2.5-distance-codes", "DEFLATE-1951-3.2.6-fixed-codes"}, "decodes distance symbol #{symbol} as distances #{base} to #{base + largest}") do |deflate|
        deflate.stored(sample(base + largest, symbol.to_u32 + 100))
        deflate.fixed(final: true) do |block|
          block.match_symbols(257, 0, symbol, 0)
          block.match_symbols(258, 0, symbol, largest - 4 > 0 ? largest - 4 : largest)
          # 0x1a2b reads differently in the two bit orders.
          block.match_symbols(259, 0, symbol, 0x1a2b & largest)
          block.match_symbols(257, 0, symbol, largest)
        end
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-reserved-symbols", "rejects distance symbol 30", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("abcdefgh")
        block.length(257).distance(30)
        block.literals("ij")
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-reserved-symbols", "rejects distance symbol 31", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("abcdefgh")
        block.length(257).distance(31)
        block.literals("ij")
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-reserved-symbols", "rejects literal/length symbol 286", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("abcdefgh")
        block.symbol(286).distance(0)
        block.literals("ij")
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-reserved-symbols", "rejects literal/length symbol 287", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("abcdefgh")
        block.symbol(287).distance(0)
        block.literals("ij")
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-reserved-symbols", "rejects a reserved symbol that is the last thing in the input", :malformed do |deflate|
      deflate.fixed(final: true, end_of_block: false) do |block|
        block.literal('a'.ord)
        block.symbol(286)
      end
    end

    it_inflates({"DEFLATE-1951-3.1.1-bit-order", "DEFLATE-1951-3.2.6-fixed-codes"}, "reads Huffman codes from the most significant bit and extra bits from the least") do |deflate|
      deflate.stored(sample(700))
      deflate.fixed(final: true) do |block|
        # Length 19 + 0b01 (2 extra bits), distance 513 + 0b00110101.
        block.match_symbols(269, 0b01, 18, 0b00110101)
        # Length 131 + 0b10011 (5 extra bits), distance 257 + 0b1010011.
        block.match_symbols(281, 0b10011, 16, 0b1010011)
        block.literals("\u0001\u0080þ")
      end
    end
  end

  describe "back references (RFC 1951 3.2.5)" do
    it_inflates "DEFLATE-1951-3.2.5-overlap", "copies a run from a reference at distance 1" do |deflate|
      deflate.fixed(final: true) do |block|
        block.literal('a'.ord)
        block.match(258, 1)
        block.match(3, 1)
      end
    end

    it_inflates "DEFLATE-1951-3.2.5-overlap", "repeats a pattern when the length passes the distance" do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("abc")
        block.match(10, 3)
        block.literals("de")
        block.match(258, 2)
        block.match(7, 5)
        block.match(200, 199)
        block.match(258, 257)
      end
    end

    it_inflates "DEFLATE-1951-3.2.5-across-blocks", "reaches from a fixed block into a stored block" do |deflate|
      deflate.stored("stored text ".to_slice)
      deflate.fixed(final: true, &.match(12, 12))
    end

    it_inflates "DEFLATE-1951-3.2.5-across-blocks", "reaches across blocks of all three types" do |deflate|
      deflate.fixed(&.literals("abcd"))
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS) do |block|
        block.match(4, 4).literals("dd").match(3, 2)
      end
      deflate.stored("-stored-".to_slice)
      deflate.fixed(&.match(20, 21).match(3, 8))
      deflate.stored(Bytes.empty)
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, final: true, &.match(258, 4).match(4, 1))
    end

    it_inflates "DEFLATE-1951-3.2.5-across-blocks", "reaches from a stored block's successor back over three blocks" do |deflate|
      deflate.fixed(&.literals("first"))
      deflate.stored(sample(300))
      deflate.stored(sample(300, 9_u32))
      deflate.fixed(final: true, &.match(5, 605).match(100, 600).match(258, 300))
    end

    it_inflates "DEFLATE-1951-3.2.5-window", "reaches exactly 32,768 bytes back to the first output byte" do |deflate|
      deflate.stored(sample(32_768))
      deflate.fixed(final: true, &.match(258, 32_768))
    end

    it_inflates "DEFLATE-1951-3.2.5-window", "reaches 32,768 bytes back after the output has passed 32,768 bytes" do |deflate|
      deflate.stored(sample(40_000))
      deflate.fixed(final: true) do |block|
        300.times do |index|
          block.match(258, 32_768)
          block.match(3 + index % 50, 32_768 - index)
          block.literal(index & 0xff)
          block.match(4, 1)
        end
      end
    end

    it_inflates "DEFLATE-1951-3.2.5-window", "reaches 32,768 bytes back across stored blocks larger than the window" do |deflate|
      deflate.stored(sample(65_535))
      deflate.stored(sample(65_535, 3_u32))
      deflate.fixed(&.match(258, 32_768).match(258, 32_767).match(258, 1))
      deflate.stored(sample(33_000, 5_u32))
      deflate.fixed(final: true, &.match(100, 32_768).match(100, 32_768))
    end

    it_inflates "DEFLATE-1951-3.2.5-window", "copies a 258-byte match that overlaps itself at distance 32,768" do |deflate|
      deflate.stored(sample(32_600))
      deflate.fixed(final: true) do |block|
        block.match(168, 32_600)
        150.times { block.match(258, 32_768) }
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-distance-too-far", "rejects a reference 32,768 back when 32,767 bytes exist", :malformed do |deflate|
      deflate.stored(sample(32_767))
      deflate.fixed(final: true, &.length(257).distance(29, 8_191))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-distance-too-far", "rejects a reference in an empty output", :malformed do |deflate|
      deflate.fixed(final: true, &.length(257).distance(0))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-distance-too-far", "rejects a reference one byte before the first output byte", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("abc")
        block.length(257).distance(3)
        block.literals("tail")
      end
    end

    it_inflates "DEFLATE-1951-3.2.5-distance-too-far", "accepts a reference to the first output byte" do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals("abc")
        block.match(3, 3)
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-distance-too-far", "rejects a far reference in the first block after earlier blocks' output", :malformed do |deflate|
      deflate.stored(sample(100))
      deflate.fixed(&.literals("abc"))
      deflate.fixed(final: true, &.length(257).distance(13, 7))
    end

    it_refuses_to_inflate "DEFLATE-API-truncation", "reports a fixed block cut inside a literal code as truncated", :truncated do |deflate|
      deflate.fixed(final: true, end_of_block: false, &.literal('a'.ord))
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-API-truncation", "reports a fixed block cut inside length extra bits as truncated", :truncated do |deflate|
      # 3 + 9 + 8 bits, then 4 of the 5 extra bits of symbol 281.
      deflate.fixed(final: true, end_of_block: false, &.literal(200).symbol(281))
    end

    it_refuses_to_inflate "DEFLATE-API-truncation", "reports a fixed block cut inside a distance code as truncated", :truncated do |deflate|
      # 3 + 8 + 7 + 2 bits, then 4 of the 5 bits of a distance code.
      deflate.fixed(final: true, end_of_block: false, &.literal('a'.ord).symbol(269))
      deflate.bit_writer.bits(0, 2)
    end

    it_refuses_to_inflate "DEFLATE-API-truncation", "reports a fixed block cut inside distance extra bits as truncated", :truncated do |deflate|
      deflate.fixed(final: true, end_of_block: false, &.literal('a'.ord).symbol(257))
      # Distance symbol 29 (code 11101) wants 13 extra bits; 6 remain.
      deflate.bit_writer.huffman(29, 5)
    end

    it_refuses_to_inflate "DEFLATE-API-truncation", "reports a fixed block without its end of block as truncated", :truncated do |deflate|
      deflate.fixed(final: true, end_of_block: false, &.literals("abc").match(3, 3))
      deflate.bit_writer.align(1)
    end

    it_satisfies "DEFLATE-API-truncation", "reports every proper prefix of a stream of fixed blocks as truncated" do
      stream = DeflateConformance.deflate do |deflate|
        deflate.fixed(&.literals("abcabc").match(200, 3).match(4, 150))
        deflate.fixed(final: true, &.match(10, 1).literals("z"))
      end
      DeflateConformance.check_every_prefix_is_truncated(:raw, stream.to_slice)
    end
  end

  describe "dynamic block headers (RFC 1951 3.2.7)" do
    it_inflates({"DEFLATE-1951-3.2.7-code-lengths", "DEFLATE-1951-3.2.7-hclen"}, "decodes a block whose code lengths are all sent literally") do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, final: true) do |block|
        block.literals("abcdabcd").match(3, 1).match(4, 2).match(258, 3).match(3, 4).literals("dcba")
      end
    end

    it_inflates "DEFLATE-1951-3.2.2-canonical-codes", "assigns codes by length first and symbol order second (the RFC 1951 3.2.2 example)" do |deflate|
      # A to H with lengths 3, 3, 3, 3, 3, 2, 4, 4, with end of block in
      # the place of H.
      literal_lengths = lengths(257, {65 => 3, 66 => 3, 67 => 3, 68 => 3, 69 => 3, 70 => 2, 71 => 4, 256 => 4})
      deflate.dynamic(literal_lengths, [0], final: true, &.literals("ABCDEFGFEDCBAGGFF"))
    end

    it_inflates "DEFLATE-1951-3.2.2-canonical-codes", "assigns codes in symbol order when the symbols are sent out of length order" do |deflate|
      literal_lengths = lengths(286, {0 => 4, 1 => 2, 2 => 4, 127 => 3, 128 => 4, 255 => 3, 256 => 4, 257 => 4, 285 => 4, 3 => 4, 4 => 4})
      distance_lengths = [3, 1, 3, 2]
      deflate.dynamic(literal_lengths, distance_lengths, final: true) do |block|
        block.literals(Bytes[0, 1, 2, 3, 4, 127, 128, 255, 255, 128, 127, 4, 3, 2, 1, 0])
        block.match(3, 1).match(258, 2).match(3, 3).match(3, 4)
      end
    end

    it_inflates "DEFLATE-1951-3.2.2-code-length-limits", "decodes literal/length and distance codes from 1 to 15 bits" do |deflate|
      literal_lengths = ladder_lengths(286, [256, 257] + (97..110).to_a)
      distance_lengths = ladder_lengths(30, (0..15).to_a)
      deflate.stored(sample(200))
      deflate.dynamic(literal_lengths, distance_lengths) do |block|
        block.literals("abcdefghijklmn")
        16.times { |symbol| block.match_symbols(257, 0, symbol, 0) }
        block.literals("nmlkjihgfedcba")
      end
      deflate.dynamic(literal_lengths, distance_lengths, final: true, &.match_symbols(257, 0, 15, 63).literals("n"))
    end

    it_inflates({"DEFLATE-1951-3.2.7-hlit", "DEFLATE-1951-3.2.7-hdist", "DEFLATE-1951-3.2.7-repeat-16"}, "decodes a block with all 286 literal/length and all 30 distance codes, sent with repeats of 3 to 6") do |deflate|
      literal_lengths = complete_lengths(286)
      distance_lengths = complete_lengths(30)
      deflate.stored(sample(32_768))
      deflate.dynamic_header(286, 30, final: true) do |code_lengths|
        # 226 codes of 8 bits and 60 of 9 bits.
        code_lengths.length(8)
        37.times { code_lengths.repeat_previous(6) }
        code_lengths.repeat_previous(3)
        code_lengths.length(9)
        9.times { code_lengths.repeat_previous(6) }
        code_lengths.repeat_previous(5)
        # 2 distance codes of 4 bits and 28 of 5 bits.
        code_lengths.length(4).length(4).length(5)
        3.times { code_lengths.repeat_previous(6) }
        code_lengths.repeat_previous(5).repeat_previous(4)
      end
      deflate.symbols(literal_lengths, distance_lengths) do |block|
        256.times { |byte| block.literal(byte) }
        257.upto(285) { |symbol| block.match_symbols(symbol, 0, (symbol - 257) % 30, 0) }
        30.times { |symbol| block.match_symbols(257 + symbol % 29, 0, symbol, (1 << DeflateConformance::DISTANCE_EXTRA_BITS[symbol]) - 1) }
      end
    end

    it_inflates({"DEFLATE-1951-3.2.7-repeat-17", "DEFLATE-1951-3.2.7-repeat-18"}, "decodes zero runs of 3, 10, 11 and 138 code lengths") do |deflate|
      deflate.dynamic_header(257, 1, final: true) do |code_lengths|
        code_lengths.zeros(65).length(2)  # 0..64 zero, 65 ("A")
        code_lengths.zeros(3).length(2)   # 66..68 zero, 69 ("E")
        code_lengths.zeros(10).length(2)  # 70..79 zero, 80 ("P")
        code_lengths.zeros(138).zeros(11) # 81..229 zero
        code_lengths.zeros(26).length(2)  # 230..255 zero, 256
        code_lengths.length(0)            # no distance codes
      end
      deflate.symbols(lengths(257, {65 => 2, 69 => 2, 80 => 2, 256 => 2}), [0], &.literals("APEPEA"))
    end

    it_inflates({"DEFLATE-1951-3.2.7-repeat-16", "DEFLATE-1951-3.2.7-repeat-17"}, "repeats a zero length with symbol 16 after a zero run") do |deflate|
      deflate.dynamic_header(257, 1, final: true) do |code_lengths|
        code_lengths.length(1)                    # literal 0
        code_lengths.zeros(10).repeat_previous(6) # 1..16 zero
        code_lengths.zeros(138).zeros(101)        # 17..255 zero
        code_lengths.length(1)                    # 256
        code_lengths.length(0)
      end
      deflate.symbols(ZERO_AND_END_LENGTHS, [0], &.literals(Bytes[0, 0, 0]))
    end

    it_inflates "DEFLATE-1951-3.2.7-one-sequence", "lets a symbol 16 repeat run from the literal/length lengths into the distance lengths" do |deflate|
      deflate.dynamic_header(258, 4, final: true) do |code_lengths|
        code_lengths.zeros(138).zeros(116) # 0..253 zero
        code_lengths.length(2)             # 254
        code_lengths.repeat_previous(6)    # 255, 256, 257, distance 0, 1 and 2
        code_lengths.length(2)             # distance 3
      end
      deflate.symbols(lengths(258, {254 => 2, 255 => 2, 256 => 2, 257 => 2}), FOUR_DISTANCE_LENGTHS) do |block|
        block.literals(Bytes[254, 255, 255, 254]).match(3, 1).match(3, 2).match(3, 3).match(3, 4)
      end
    end

    it_inflates "DEFLATE-1951-3.2.7-one-sequence", "lets a zero run from the literal/length lengths end inside the distance lengths" do |deflate|
      deflate.dynamic_header(258, 4, final: true) do |code_lengths|
        code_lengths.length(1)             # literal 0
        code_lengths.zeros(138).zeros(117) # 1..255 zero
        code_lengths.length(1)             # 256
        code_lengths.zeros(3)              # 257, distance 0 and 1
        code_lengths.length(1).length(1)   # distance 2 and 3
      end
      deflate.symbols(lengths(258, {0 => 1, 256 => 1}), [0, 0, 1, 1], &.literals(Bytes[0, 0, 0, 0, 0]))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-repeat-16", "rejects symbol 16 as the first code length", :malformed do |deflate|
      # Read with a previous length of 0, the header would be valid.
      deflate.dynamic_header(257, 1, final: true) do |code_lengths|
        code_lengths.repeat_previous(3)    # 0..2
        code_lengths.zeros(138).zeros(115) # 3..255
        code_lengths.length(1).length(0)   # 256 and no distance codes
      end
      deflate.bit_writer.bits(0, 1).align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-repeat-overrun", "rejects a symbol 16 repeat that passes the last code length by one", :malformed do |deflate|
      deflate.dynamic_header(257, 1, final: true) do |code_lengths|
        code_lengths.zeros(138).zeros(117) # 0..254 zero
        code_lengths.length(1)             # 255
        code_lengths.repeat_previous(3)    # 256, distance 0, and one too many
      end
      deflate.bit_writer.bits(1, 1).align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-repeat-overrun", "rejects a symbol 17 zero run that passes the last code length", :malformed do |deflate|
      deflate.dynamic_header(257, 1, final: true) do |code_lengths|
        code_lengths.length(1)             # literal 0
        code_lengths.zeros(138).zeros(117) # 1..255 zero
        code_lengths.length(1)             # 256
        code_lengths.zeros(3)              # distance 0, and two too many
      end
      deflate.bit_writer.bits(1, 1).align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-repeat-overrun", "rejects a symbol 18 zero run that passes the last code length", :malformed do |deflate|
      deflate.dynamic_header(257, 10, final: true) do |code_lengths|
        code_lengths.length(1)             # literal 0
        code_lengths.zeros(138).zeros(117) # 1..255 zero
        code_lengths.length(1)             # 256
        code_lengths.zeros(11)             # distance 0..9, and one too many
      end
      deflate.bit_writer.bits(1, 1).align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-repeat-overrun", "rejects a 138-length zero run in a 258-length sequence that has 137 left", :malformed do |deflate|
      deflate.dynamic_header(257, 1, final: true) do |code_lengths|
        code_lengths.length(1).zeros(120) # literal 0, 1..120 zero
        code_lengths.zeros(138)           # 121..257, one too many
      end
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-hlit", "rejects 287 literal/length code lengths", :malformed do |deflate|
      deflate.dynamic(complete_lengths(286) + [0], complete_lengths(30), final: true, &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-hlit", "rejects 288 literal/length code lengths", :malformed do |deflate|
      deflate.dynamic(complete_lengths(286) + [0, 0], complete_lengths(30), final: true, &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-hlit", "rejects 288 literal/length code lengths that spell the fixed code", :malformed do |deflate|
      deflate.dynamic(DeflateConformance::FIXED_LITERAL_LENGTHS, complete_lengths(30), final: true, &.literals("abc"))
    end

    it_inflates "DEFLATE-1951-3.2.7-hlit", "accepts 257 literal/length code lengths, the fewest HLIT can declare" do |deflate|
      deflate.dynamic(lengths(257, {97 => 1, 256 => 1}), [0], final: true, &.literals("aaa"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-hdist", "rejects 31 distance code lengths", :malformed do |deflate|
      deflate.dynamic(complete_lengths(286), complete_lengths(30) + [0], final: true, &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-hdist", "rejects 32 distance code lengths", :malformed do |deflate|
      deflate.dynamic(complete_lengths(286), complete_lengths(30) + [0, 0], final: true, &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-hdist", "rejects 32 distance code lengths that spell the fixed code", :malformed do |deflate|
      deflate.dynamic(complete_lengths(286), DeflateConformance::FIXED_DISTANCE_LENGTHS, final: true, &.literals("abc"))
    end

    it_inflates "DEFLATE-1951-3.2.7-hclen", "reads four to nineteen code length code lengths and takes the rest as zero" do |deflate|
      # HCLEN 5 sends the lengths of 16, 17, 18, 0 and 8 only: literals 1
      # to 255 and end of block get 8 bits each.
      code_length_code_lengths = lengths(19, {0 => 1, 8 => 1})
      deflate.dynamic_header(257, 1, list_of_code_length_code_lengths: code_length_code_lengths, code_length_count: 5) do |code_lengths|
        code_lengths.length(0)
        256.times { code_lengths.length(8) }
        code_lengths.length(0)
      end
      deflate.symbols(lengths(257, (1..256).to_h { |symbol| {symbol, 8} }), [0]) do |block|
        1.upto(255) { |byte| block.literal(byte) }
      end
      # HCLEN 12 stops after the length of symbol 4: literals 0 to 14 and
      # end of block get 4 bits each.
      code_length_code_lengths = lengths(19, {16 => 2, 0 => 2, 4 => 2, 5 => 2})
      deflate.dynamic_header(257, 1, final: true, list_of_code_length_code_lengths: code_length_code_lengths, code_length_count: 12) do |code_lengths|
        code_lengths.length(4).repeat_previous(6).repeat_previous(6).length(4).length(4) # 0..14
        241.times { code_lengths.length(0) }                                             # 15..255
        code_lengths.length(4).length(0)                                                 # 256, no distance codes
      end
      deflate.symbols(lengths(257, (0..14).to_h { |symbol| {symbol, 4} }.merge({256 => 4})), [0]) do |block|
        15.times { |byte| block.literal(byte) }
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-hclen", "rejects a header whose four code length code lengths can only spell zero lengths", :malformed do |deflate|
      deflate.dynamic_header(257, 1, final: true, list_of_code_length_code_lengths: lengths(19, {18 => 1, 0 => 1}), code_length_count: 4) do |code_lengths|
        code_lengths.zeros(138).zeros(120)
      end
      deflate.bit_writer.align(1)
    end

    it_inflates "DEFLATE-1951-3.2.7-code-length-code", "decodes code length codes of 1 to 7 bits" do |deflate|
      code_length_code_lengths = lengths(19, {0 => 1, 18 => 2, 17 => 3, 16 => 4, 1 => 5, 2 => 6, 3 => 7, 4 => 7})
      deflate.dynamic_header(257, 4, final: true, list_of_code_length_code_lengths: code_length_code_lengths) do |code_lengths|
        code_lengths.zeros(97)                               # 0..96 zero
        code_lengths.length(2).length(3).length(4).length(4) # "abcd"
        code_lengths.zeros(138).zeros(17)                    # 101..255 zero
        code_lengths.length(1)                               # 256
        code_lengths.length(2).repeat_previous(3)            # four distance codes
      end
      deflate.symbols(lengths(257, {97 => 2, 98 => 3, 99 => 4, 100 => 4, 256 => 1}), FOUR_DISTANCE_LENGTHS, &.literals("abcddcba"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-code-length-code", "rejects an incomplete code length code of three 2-bit codes", :malformed do |deflate|
      # With the fourth code unassigned, the rest of the block is valid.
      deflate.dynamic_header(257, 1, final: true, list_of_code_length_code_lengths: lengths(19, {0 => 2, 8 => 2, 18 => 2})) do |code_lengths|
        code_lengths.length(0)
        256.times { code_lengths.length(8) }
        code_lengths.length(0)
      end
      deflate.symbols(lengths(257, (1..256).to_h { |symbol| {symbol, 8} }), [0], &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-code-length-code", "rejects an incomplete code length code of a 1-bit and a 2-bit code", :malformed do |deflate|
      deflate.dynamic_header(257, 1, final: true, list_of_code_length_code_lengths: lengths(19, {8 => 1, 0 => 2})) do |code_lengths|
        code_lengths.length(0)
        256.times { code_lengths.length(8) }
        code_lengths.length(0)
      end
      deflate.symbols(lengths(257, (1..256).to_h { |symbol| {symbol, 8} }), [0], &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-code-length-code", "rejects a code length code with a single 1-bit code", :malformed do |deflate|
      # zlib accepts a lone 1-bit code only for the literal/length and
      # distance codes, not here.
      deflate.dynamic_header(257, 1, final: true, list_of_code_length_code_lengths: lengths(19, {0 => 1})) do |code_lengths|
        258.times { code_lengths.length(0) }
      end
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate({"DEFLATE-1951-3.2.2-oversubscribed", "DEFLATE-1951-3.2.7-code-length-code"}, "rejects an oversubscribed code length code", :malformed) do |deflate|
      deflate.dynamic_header(257, 1, final: true, list_of_code_length_code_lengths: lengths(19, {0 => 1, 8 => 1, 18 => 1})) do |code_lengths|
        code_lengths.length(0)
        256.times { code_lengths.length(8) }
        code_lengths.length(0)
      end
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-oversubscribed", "rejects an oversubscribed literal/length code", :malformed do |deflate|
      deflate.dynamic(lengths(257, {97 => 1, 98 => 1, 256 => 1}), [0], final: true, end_of_block: false) { }
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-oversubscribed", "rejects a literal/length code oversubscribed by one 15-bit code", :malformed do |deflate|
      literal_lengths = ladder_lengths(286, [256, 257] + (97..110).to_a)
      literal_lengths[120] = 15
      deflate.dynamic(literal_lengths, [0], final: true, end_of_block: false) { }
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-oversubscribed", "rejects an oversubscribed distance code", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [1, 1, 1], final: true, &.literals("abcd"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-oversubscribed", "rejects 286 literal/length codes of 8 bits", :malformed do |deflate|
      deflate.dynamic(Array.new(286, 8), [0], final: true, &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-incomplete", "rejects an incomplete literal/length code of three 2-bit codes", :malformed do |deflate|
      deflate.dynamic(lengths(257, {97 => 2, 98 => 2, 256 => 2}), [0], final: true, &.literals("abab"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-incomplete", "rejects a literal/length code one 15-bit code short of complete", :malformed do |deflate|
      literal_lengths = ladder_lengths(286, [256, 257] + (97..110).to_a)
      literal_lengths[110] = 0
      deflate.dynamic(literal_lengths, [0], final: true, &.literals("abc"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-incomplete", "rejects a literal/length code of one 2-bit code", :malformed do |deflate|
      deflate.dynamic(lengths(257, {256 => 2}), [0], final: true) { }
    end

    it_inflates "DEFLATE-1951-3.2.2-incomplete", "accepts a literal/length code of one 1-bit code, the end of block (as zlib does)" do |deflate|
      deflate.fixed(&.literals("before "))
      deflate.dynamic(lengths(257, {256 => 1}), [0]) { }
      deflate.dynamic(lengths(286, {256 => 1}), Array.new(30, 0)) { }
      deflate.fixed(final: true, &.literals("after"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-unused-code", "rejects the unassigned code of a one-code literal/length code", :malformed do |deflate|
      deflate.dynamic(lengths(257, {256 => 1}), [0], final: true, end_of_block: false) { }
      deflate.bit_writer.bits(1, 1).align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-incomplete", "rejects an incomplete distance code of two 2-bit codes", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [2, 2], final: true, &.literals("abcd").match(3, 1))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-incomplete", "rejects an incomplete distance code of a 1-bit and a 2-bit code", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [1, 2], final: true, &.literals("abcd").match(3, 1))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-incomplete", "rejects a distance code of one 2-bit code", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [2], final: true, &.literals("abcd").match(3, 1))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-incomplete", "rejects a distance code of one 15-bit code", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [15], final: true, &.literals("abcd"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-end-of-block-code", "rejects a complete literal/length code without symbol 256", :malformed do |deflate|
      deflate.dynamic(lengths(257, {97 => 1, 98 => 1}), [0], final: true, end_of_block: false, &.literals("abab"))
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-end-of-block-code", "rejects a one-code literal/length code whose code is a literal", :malformed do |deflate|
      deflate.dynamic(lengths(257, {97 => 1}), [0], final: true, end_of_block: false, &.literals("aaa"))
      deflate.bit_writer.align(1)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-end-of-block-code", "rejects literal/length code lengths that are all zero", :malformed do |deflate|
      deflate.dynamic(Array.new(257, 0), [0], final: true, end_of_block: false) { }
      deflate.bit_writer.align(1)
    end

    it_inflates "DEFLATE-1951-3.2.7-no-distance-codes", "accepts one distance code length of zero for a block of literals" do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [0], final: true, &.literals("abcdabcd"))
    end

    it_inflates "DEFLATE-1951-3.2.7-no-distance-codes", "accepts thirty distance code lengths of zero for a block of literals" do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, Array.new(30, 0), final: true, &.literals("dcba"))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-no-distance-codes", "rejects a length symbol in a block with no distance codes", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [0], final: true) do |block|
        block.literals("abcd").symbol(257)
        deflate.bit_writer.bits(0, 1)
        block.literals("abcd")
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-no-distance-codes", "rejects a length symbol at the end of the input in a block with no distance codes", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [0], final: true, end_of_block: false, &.literals("abcd").symbol(257))
      deflate.bit_writer.align(1)
    end

    it_inflates "DEFLATE-1951-3.2.7-single-distance-code", "decodes a single 1-bit distance code for distance 1" do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [1], final: true, &.literals("ab").match(3, 1).match(258, 1).literals("cd"))
    end

    it_inflates "DEFLATE-1951-3.2.7-single-distance-code", "decodes a single 1-bit distance code for a symbol with extra bits" do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, lengths(30, {4 => 1}), final: true) do |block|
        block.literals("abcdab").match(3, 5).match(4, 6)
      end
    end

    it_inflates "DEFLATE-1951-3.2.7-single-distance-code", "decodes a single 1-bit distance code for symbol 29" do |deflate|
      deflate.stored(sample(32_768))
      deflate.dynamic(ABCD_LITERAL_LENGTHS, lengths(30, {29 => 1}), final: true, &.match(3, 24_577).match(258, 32_768))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-unused-code", "rejects the unassigned code of a one-code distance code", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [1], final: true) do |block|
        block.literals("abcd").symbol(257)
        deflate.bit_writer.bits(1, 1)
        block.literals("abcd")
      end
    end

    it_inflates "DEFLATE-1951-3.2.7-single-distance-code", "decodes a complete distance code of two 1-bit codes" do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [1, 1], final: true, &.literals("abcd").match(3, 1).match(3, 2).match(4, 2))
    end

    it_refuses_to_inflate "DEFLATE-API-truncation", "reports a dynamic block cut inside its symbols as truncated", :truncated do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, final: true, end_of_block: false, &.literals("abcd").match(3, 1))
      # The 3-bit code 111 is length symbol 285; its 2-bit distance code is cut.
      deflate.bit_writer.align(1)
    end

    dynamic = DeflateConformance.deflate do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, final: true, &.literals("abcd").match(258, 4).match(3, 1))
    end.to_slice
    {1 => "inside HLIT", 2 => "inside HCLEN", 4 => "inside the code length code lengths", 9 => "at the first code length", 60 => "inside the literal/length code lengths", dynamic.size - 6 => "inside the distance code lengths", dynamic.size - 1 => "inside the symbols"}.each do |size, place|
      it_rejects_vector "DEFLATE-API-truncation", "reports a dynamic block cut #{place} as truncated", :raw, dynamic[0, size], :truncated
    end

    it_satisfies "DEFLATE-API-truncation", "reports every proper prefix of a stream of dynamic blocks as truncated" do
      stream = DeflateConformance.deflate do |deflate|
        deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, &.literals("abcd").match(258, 4))
        deflate.dynamic(lengths(257, {256 => 1}), [0]) { }
        deflate.dynamic(ABCD_LITERAL_LENGTHS, [1], final: true, &.match(3, 1).literals("d"))
      end
      DeflateConformance.check_every_prefix_is_truncated(:raw, stream.to_slice)
    end
  end

  # The same errors with hundreds of bytes on both sides, where a decoder's
  # bulk loop (not its careful end-of-input loop) meets them. The streaming
  # specs require the Reader to report each at the same input offset.
  describe "errors in the middle of long blocks" do
    filler = "the quick brown fox jumps over the lazy dog. " * 12

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-reserved-symbols", "rejects distance symbol 30 deep inside a long fixed block", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals(filler).match(40, 45)
        block.length(260).distance(30)
        block.literals(filler)
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-reserved-symbols", "rejects literal/length symbol 287 deep inside a long fixed block", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals(filler).match(258, 90)
        block.symbol(287)
        block.literals(filler)
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.5-distance-too-far", "rejects a reference before the first output byte deep inside a long fixed block", :malformed do |deflate|
      deflate.fixed(final: true) do |block|
        block.literals(filler).match(100, 540)
        block.length(257).distance(19, 255)
        block.literals(filler)
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-unused-code", "rejects the unassigned code of a one-code distance code deep inside a long dynamic block", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [1], final: true) do |block|
        200.times { block.literals("abcd").match(3, 1) }
        block.symbol(258)
        deflate.bit_writer.bits(1, 1)
        200.times { block.literals("dcba") }
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.7-no-distance-codes", "rejects a length symbol deep inside a long dynamic block with no distance codes", :malformed do |deflate|
      deflate.dynamic(ABCD_LITERAL_LENGTHS, [0], final: true) do |block|
        300.times { block.literals("abcd") }
        block.symbol(285)
        300.times { block.literals("dcba") }
      end
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.2-unused-code", "rejects the unassigned code of a one-code literal/length code followed by more input", :malformed do |deflate|
      deflate.fixed(&.literals(filler))
      deflate.dynamic(lengths(257, {256 => 1}), [0], final: true, end_of_block: false) { }
      deflate.bit_writer.bits(1, 1).align.bytes(filler.to_slice)
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.3-reserved-block-type", "rejects block type 3 between long blocks", :malformed do |deflate|
      deflate.fixed(&.literals(filler))
      deflate.block_header(3, final: false)
      deflate.fixed(final: true, &.literals(filler))
    end

    it_refuses_to_inflate "DEFLATE-1951-3.2.4-stored-length", "rejects a wrong NLEN between long blocks", :malformed do |deflate|
      deflate.fixed(&.literals(filler))
      deflate.stored(filler.to_slice, declared_complement: 0x1234)
      deflate.fixed(final: true, &.literals(filler))
    end
  end

  describe ".decode" do
    it_satisfies "DEFLATE-API-one-shot", "returns the output of a multi-block stream as Bytes" do
      stream = DeflateConformance.deflate do |deflate|
        deflate.stored("one ".to_slice).fixed(&.literals("two ").match(4, 8))
        deflate.dynamic(ABCD_LITERAL_LENGTHS, FOUR_DISTANCE_LENGTHS, final: true, &.literals("abcd"))
      end
      output = Mica::Deflate.decode(stream.to_slice, limits: DeflateConformance::LIMITS, timeout: nil)
      output.should be_a(Bytes)
      String.new(output).should eq("one two one abcd")
    end

    it_satisfies "DEFLATE-API-errors", "raises MalformedStreamError, a Mica::ParseError, with the byte offset of the problem" do
      # Byte 5, after an empty stored block, holds the reserved block type.
      input = DeflateConformance.deflate(&.stored(Bytes.empty).block_header(3, final: true)).to_slice
      error = expect_raises(Mica::Deflate::MalformedStreamError) do
        Mica::Deflate.decode(input, limits: DeflateConformance::LIMITS, timeout: nil)
      end
      error.should be_a(Mica::ParseError)
      error.should be_a(Mica::Error)
      error.should_not be_a(Mica::Deflate::TruncatedStreamError)
      error.should_not be_a(Mica::Deflate::ChecksumError)
      [5_i64, 6_i64].should contain(error.byte_offset)
    end

    it_satisfies "DEFLATE-API-errors", "raises TruncatedStreamError, a MalformedStreamError, at the end of the input" do
      input = DeflateConformance.deflate(&.stored("abcdef".to_slice, final: true)).to_slice[0, 7]
      error = expect_raises(Mica::Deflate::TruncatedStreamError) do
        Mica::Deflate.decode(input, limits: DeflateConformance::LIMITS, timeout: nil)
      end
      error.should be_a(Mica::Deflate::MalformedStreamError)
      error.byte_offset.should eq(7)
    end
  end
end
