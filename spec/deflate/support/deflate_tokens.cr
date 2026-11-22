require "./bit_writer"

# Support for the encoder specs: reads a raw DEFLATE stream (RFC 1951)
# block by block and reports what each block is made of (its type, its
# literals and its matches), so a spec can state what the encoder wrote,
# for example that a match reaches 32,768 bytes back. It is a plain
# bit-at-a-time reader written from the RFC, independent of Mica's
# Inflater.
module DeflateTokens
  # One back reference.
  record Match, length : Int32, distance : Int32

  # One block: *type* is 0 (stored), 1 (fixed) or 2 (dynamic);
  # *output_start* is the offset of its first byte in the decoded output.
  record Block, type : Int32, is_final : Bool, literal_count : Int32, stored_bytes : Int32,
    list_of_matches : Array(Match), output_start : Int64

  private class BitReader
    getter position : Int32 = 0

    def initialize(@bytes : Bytes)
      @bit = 0
    end

    def bit : Int32
      raise "the stream ends inside a block" if @position >= @bytes.size
      value = (@bytes[@position].to_i32 >> @bit) & 1
      @bit += 1
      if @bit == 8
        @bit = 0
        @position += 1
      end
      value
    end

    def bits(count : Int32) : Int32
      value = 0
      count.times { |index| value |= bit << index }
      value
    end

    def align : Nil
      return if @bit == 0
      @bit = 0
      @position += 1
    end

    def skip(count : Int32) : Nil
      @position += count
    end
  end

  # A canonical Huffman code read one bit at a time (the method of zlib's
  # contrib/puff).
  private class Code
    @counts : Array(Int32)
    @symbols : Array(Int32)

    def initialize(lengths : Array(Int32))
      @counts = Array.new(16, 0)
      lengths.each { |length| @counts[length] += 1 }
      @counts[0] = 0
      offsets = Array.new(16, 0)
      1.upto(15) { |length| offsets[length] = offsets[length - 1] + @counts[length - 1] }
      @symbols = Array.new(lengths.size, 0)
      lengths.each_with_index do |length, symbol|
        next if length == 0
        @symbols[offsets[length]] = symbol
        offsets[length] += 1
      end
    end

    def read(reader : BitReader) : Int32
      code = 0
      first = 0
      index = 0
      1.upto(15) do |length|
        code |= reader.bit
        count = @counts[length]
        return @symbols[index + (code - first)] if code - count < first
        index += count
        first = (first + count) << 1
        code <<= 1
      end
      raise "invalid Huffman code"
    end
  end

  # Reads every block of the raw DEFLATE stream *raw*.
  def self.read(raw : Bytes) : Array(Block)
    reader = BitReader.new(raw)
    list_of_blocks = [] of Block
    produced = 0_i64
    loop do
      is_final = reader.bit == 1
      type = reader.bits(2)
      literal_count = 0
      stored_bytes = 0
      list_of_matches = [] of Match
      output_start = produced
      case type
      when 0
        reader.align
        stored_bytes = reader.bits(16)
        complement = reader.bits(16)
        raise "stored block lengths disagree" unless stored_bytes == (~complement & 0xFFFF)
        reader.skip(stored_bytes)
        produced += stored_bytes
      when 1, 2
        literal_code, distance_code = type == 1 ? fixed_codes : dynamic_codes(reader)
        loop do
          symbol = literal_code.read(reader)
          break if symbol == 256
          if symbol < 256
            literal_count += 1
            produced += 1
            next
          end
          length = DeflateConformance::LENGTH_BASE[symbol - 257] + reader.bits(DeflateConformance::LENGTH_EXTRA_BITS[symbol - 257])
          distance_symbol = distance_code.read(reader)
          distance = DeflateConformance::DISTANCE_BASE[distance_symbol] +
                     reader.bits(DeflateConformance::DISTANCE_EXTRA_BITS[distance_symbol])
          list_of_matches << Match.new(length, distance)
          produced += length
        end
      else
        raise "reserved block type"
      end
      list_of_blocks << Block.new(type, is_final, literal_count, stored_bytes, list_of_matches, output_start)
      break if is_final
    end
    list_of_blocks
  end

  private def self.fixed_codes : {Code, Code}
    {Code.new(DeflateConformance::FIXED_LITERAL_LENGTHS), Code.new(Array.new(30, 5))}
  end

  private def self.dynamic_codes(reader : BitReader) : {Code, Code}
    literal_count = reader.bits(5) + 257
    distance_count = reader.bits(5) + 1
    code_length_count = reader.bits(4) + 4
    code_length_lengths = Array.new(19, 0)
    code_length_count.times { |index| code_length_lengths[DeflateConformance::CODE_LENGTH_ORDER[index]] = reader.bits(3) }
    code_length_code = Code.new(code_length_lengths)
    lengths = [] of Int32
    while lengths.size < literal_count + distance_count
      symbol = code_length_code.read(reader)
      case symbol
      when 16 then (3 + reader.bits(2)).times { lengths << lengths.last }
      when 17 then (3 + reader.bits(3)).times { lengths << 0 }
      when 18 then (11 + reader.bits(7)).times { lengths << 0 }
      else         lengths << symbol
      end
    end
    {Code.new(lengths[0, literal_count]), Code.new(lengths[literal_count, distance_count])}
  end
end
