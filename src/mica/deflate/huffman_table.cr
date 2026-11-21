module Mica::Deflate
  # Builds the lookup tables the inflater decodes Huffman codes with
  # (canonical codes, RFC 1951 section 3.2.2), in the two-level layout zlib
  # and libdeflate use: a root table indexed by the next `root` bits of the
  # input (codes are stored bit-reversed, as DEFLATE sends them), and for
  # codes longer than `root` bits a subtable sized to fit them.
  #
  # Each entry is a `UInt32`:
  #
  # | Bits  | Meaning |
  # |-------|---------|
  # | 0-7   | code bits this entry consumes |
  # | 8-11  | code bits (lengths, distances: bits 0-7 then hold code plus extra bits) or subtable index bits |
  # | 13    | `SUBTABLE`: bits 16-31 hold the subtable's start |
  # | 14    | `END_OF_BLOCK` |
  # | 15    | `EXCEPTIONAL`: end of block, subtable or invalid code |
  # | 16-30 | literal byte, length or distance base, code-length symbol |
  # | 31    | `LITERAL` |
  #
  # An entry with `EXCEPTIONAL` and neither `SUBTABLE` nor `END_OF_BLOCK`
  # marks a bit pattern no code uses (an incomplete code, or symbols 286,
  # 287, 30 and 31 of the fixed codes) and fails the decode.
  #
  # :nodoc:
  module HuffmanTable
    LITERAL      = 0x8000_0000_u32
    EXCEPTIONAL  = 0x0000_8000_u32
    END_OF_BLOCK = 0x0000_4000_u32
    SUBTABLE     = 0x0000_2000_u32
    # A bit pattern no code uses. It takes one bit, as zlib's unused
    # entries do: they occur only in an empty code or a one-code code of
    # length 1, so a decoder judges the pattern on that one bit.
    INVALID = EXCEPTIONAL | 1_u32

    # Root bits per alphabet.
    LITERAL_LENGTH_ROOT = 10
    DISTANCE_ROOT       =  8
    CODE_LENGTH_ROOT    =  7

    # Entries each table may need, root plus subtables, rounded up from
    # zlib's `enough` bounds (1,332 for 286 symbols with a 10-bit root, 402
    # for 30 symbols with an 8-bit root). The builder checks the bound
    # anyway.
    LITERAL_LENGTH_ENTRIES = 2_048
    DISTANCE_ENTRIES       = 1_024
    CODE_LENGTH_ENTRIES    =   128

    # Base length and extra bits of length symbols 257 to 285.
    LENGTH_BASES = StaticArray[3_u16, 4_u16, 5_u16, 6_u16, 7_u16, 8_u16, 9_u16, 10_u16, 11_u16, 13_u16, 15_u16, 17_u16,
      19_u16, 23_u16, 27_u16, 31_u16, 35_u16, 43_u16, 51_u16, 59_u16, 67_u16, 83_u16, 99_u16, 115_u16,
      131_u16, 163_u16, 195_u16, 227_u16, 258_u16]
    LENGTH_EXTRA = StaticArray[0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 1_u8, 2_u8, 2_u8, 2_u8,
      2_u8, 3_u8, 3_u8, 3_u8, 3_u8, 4_u8, 4_u8, 4_u8, 4_u8, 5_u8, 5_u8, 5_u8, 5_u8, 0_u8]
    # Base distance and extra bits of distance symbols 0 to 29.
    DISTANCE_BASES = StaticArray[1_u16, 2_u16, 3_u16, 4_u16, 5_u16, 7_u16, 9_u16, 13_u16, 17_u16, 25_u16, 33_u16, 49_u16,
      65_u16, 97_u16, 129_u16, 193_u16, 257_u16, 385_u16, 513_u16, 769_u16, 1025_u16, 1537_u16, 2049_u16,
      3073_u16, 4097_u16, 6145_u16, 8193_u16, 12289_u16, 16385_u16, 24577_u16]
    DISTANCE_EXTRA = StaticArray[0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 2_u8, 2_u8, 3_u8, 3_u8, 4_u8, 4_u8, 5_u8, 5_u8, 6_u8,
      6_u8, 7_u8, 7_u8, 8_u8, 8_u8, 9_u8, 9_u8, 10_u8, 10_u8, 11_u8, 11_u8, 12_u8, 12_u8, 13_u8, 13_u8]

    # Which alphabet a table decodes; it decides each symbol's entry and
    # whether an incomplete code is allowed.
    enum Alphabet
      CodeLength
      LiteralLength
      Distance
    end

    # Why a set of code lengths does not form a usable code.
    enum Problem
      None
      Oversubscribed
      Incomplete
    end

    # Fills *table* (with room for *capacity* entries) for the code whose
    # lengths are `lengths[0, count]`, with a *root*-bit root table.
    # Returns the problem, if any, and the entries written (the work the
    # build did).
    #
    # Follows zlib's acceptance rules: an oversubscribed code is always
    # rejected; an incomplete code is accepted only for the literal/length
    # and distance alphabets and only when it is a single code of length 1;
    # a code with no symbols at all is accepted and every bit pattern of it
    # decodes as invalid.
    def self.build(table : UInt32*, capacity : Int32, lengths : UInt8*, count : Int32, root : Int32,
                   alphabet : Alphabet) : {Problem, Int32}
      counts = StaticArray(Int32, 16).new(0)
      count.times { |symbol| counts[lengths[symbol]] += 1 }
      max_length = 15
      while max_length > 0 && counts[max_length] == 0
        max_length -= 1
      end
      root_size = 1 << root
      if max_length == 0
        root_size.times { |index| table[index] = INVALID }
        return {Problem::None, root_size}
      end
      left = 1
      (1..15).each do |length|
        left <<= 1
        left -= counts[length]
        return {Problem::Oversubscribed, 0} if left < 0
      end
      if left > 0 && (alphabet.code_length? || max_length != 1)
        return {Problem::Incomplete, 0}
      end

      offsets = StaticArray(Int32, 16).new(0)
      (1...15).each { |length| offsets[length + 1] = offsets[length] + counts[length] }
      sorted = uninitialized StaticArray(UInt16, 320)
      count.times do |symbol|
        length = lengths[symbol]
        next if length == 0
        sorted[offsets[length]] = symbol.to_u16
        offsets[length] += 1
      end

      # A complete code writes every entry itself; only an incomplete one
      # (a single 1-bit code) leaves patterns that must read as invalid.
      complete = left == 0
      written = 0
      unless complete
        root_size.times { |index| table[index] = INVALID }
        written = root_size
      end
      root_mask = root_size - 1
      next_free = root_size
      current_prefix = -1
      subtable_start = 0
      subtable_bits = 0
      code = 0
      position = 0
      (1..max_length).each do |length|
        counts[length].times do
          symbol = sorted[position].to_i32
          position += 1
          reversed = reverse(code, length)
          if length <= root
            filled = entry_for(alphabet, symbol, length)
            index = reversed
            step = 1 << length
            while index < root_size
              table[index] = filled
              index += step
              written += 1
            end
          else
            prefix = reversed & root_mask
            if prefix != current_prefix
              bits = length - root
              room = 1 << bits
              while bits + root < max_length
                room -= counts[bits + root]
                break if room <= 0
                bits += 1
                room <<= 1
              end
              subtable_bits = bits
              subtable_start = next_free
              next_free += 1 << bits
              raise Mica::Error.new("internal error: Huffman table overflow") if next_free > capacity
              unless complete
                (1 << bits).times { |index| table[subtable_start + index] = INVALID }
                written += 1 << bits
              end
              table[prefix] = EXCEPTIONAL | SUBTABLE | (subtable_start.to_u32 << 16) |
                              (subtable_bits.to_u32 << 8) | root.to_u32
              current_prefix = prefix
            end
            filled = entry_for(alphabet, symbol, length - root)
            index = reversed >> root
            step = 1 << (length - root)
            size = 1 << subtable_bits
            while index < size
              table[subtable_start + index] = filled
              index += step
              written += 1
            end
          end
          counts[length] -= 1
          code += 1
        end
        code <<= 1
      end
      {Problem::None, written}
    end

    # Returns the entry for *symbol* whose code takes *code_bits* bits at
    # this level of the table.
    private def self.entry_for(alphabet : Alphabet, symbol : Int32, code_bits : Int32) : UInt32
      bits = code_bits.to_u32
      case alphabet
      in .code_length?
        (symbol.to_u32 << 16) | bits
      in .literal_length?
        if symbol < 256
          LITERAL | (symbol.to_u32 << 16) | bits
        elsif symbol == 256
          EXCEPTIONAL | END_OF_BLOCK | bits
        elsif symbol <= 285
          index = symbol - 257
          with_extra(LENGTH_BASES[index], LENGTH_EXTRA[index], bits)
        else
          EXCEPTIONAL | bits
        end
      in .distance?
        if symbol < 30
          with_extra(DISTANCE_BASES[symbol], DISTANCE_EXTRA[symbol], bits)
        else
          EXCEPTIONAL | bits
        end
      end
    end

    # A length or distance entry: bits 0-7 hold the code bits plus the
    # extra bits, bits 8-11 the code bits, so a decoder takes both with one
    # shift and reads the extra value as `(bits & mask(total)) >> code`.
    private def self.with_extra(base : UInt16, extra : UInt8, code_bits : UInt32) : UInt32
      (base.to_u32 << 16) | (code_bits << 8) | (code_bits + extra.to_u32)
    end

    # Returns the low *length* bits of *code* in reverse order.
    private def self.reverse(code : Int32, length : Int32) : Int32
      value = code.to_u32
      value = ((value >> 1) & 0x5555_5555_u32) | ((value & 0x5555_5555_u32) << 1)
      value = ((value >> 2) & 0x3333_3333_u32) | ((value & 0x3333_3333_u32) << 2)
      value = ((value >> 4) & 0x0F0F_0F0F_u32) | ((value & 0x0F0F_0F0F_u32) << 4)
      value = ((value >> 8) & 0x00FF_00FF_u32) | ((value & 0x00FF_00FF_u32) << 8)
      value = (value >> 16) | (value << 16)
      (value >> (32 - length)).to_i32
    end

    # The fixed literal/length table (RFC 1951, section 3.2.6): symbols 0
    # to 143 have 8 bits, 144 to 255 have 9, 256 to 279 have 7 and 280 to
    # 287 have 8. Symbols 286 and 287 decode as invalid.
    FIXED_LITERAL_LENGTH = begin
      lengths = StaticArray(UInt8, 288).new(0_u8)
      288.times do |symbol|
        lengths[symbol] = symbol < 144 ? 8_u8 : symbol < 256 ? 9_u8 : symbol < 280 ? 7_u8 : 8_u8
      end
      table = Slice(UInt32).new(LITERAL_LENGTH_ENTRIES, INVALID)
      build(table.to_unsafe, table.size, lengths.to_unsafe, 288, LITERAL_LENGTH_ROOT, Alphabet::LiteralLength)
      table
    end

    # The fixed distance table: 32 codes of 5 bits; 30 and 31 decode as
    # invalid.
    FIXED_DISTANCE = begin
      lengths = StaticArray(UInt8, 32).new(5_u8)
      table = Slice(UInt32).new(DISTANCE_ENTRIES, INVALID)
      build(table.to_unsafe, table.size, lengths.to_unsafe, 32, DISTANCE_ROOT, Alphabet::Distance)
      table
    end
  end
end
