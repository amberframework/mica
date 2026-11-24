module Mica::HPACK
  # The integer representation of RFC 7541 section 5.1: a value in the low
  # *prefix* bits (5 to 8) of a first octet, continued in 7-bit groups when
  # it does not fit.
  #
  # ```
  # io = IO::Memory.new
  # Mica::HPACK::PrefixInteger.encode(io, 0x00_u8, 5, 1_337_i64)
  # io.to_slice                                          # => Bytes[0x1f, 0x9a, 0x0a]
  # Mica::HPACK::PrefixInteger.decode(io.to_slice, 0, 5) # => {1337, 3}
  # ```
  module PrefixInteger
    # Writes *value* in the low *prefix* bits of a first octet whose high
    # bits are *pattern*'s.
    def self.encode(output : IO, pattern : UInt8, prefix : Int32, value : Int64) : Nil
      check_prefix(prefix)
      raise ArgumentError.new("value must not be negative") if value < 0
      mask = (1_i64 << prefix) - 1
      if value < mask
        output.write_byte(pattern | value.to_u8)
        return
      end
      output.write_byte(pattern | mask.to_u8!)
      value -= mask
      while value >= 0x80
        output.write_byte(((value & 0x7f) | 0x80).to_u8)
        value >>= 7
      end
      output.write_byte(value.to_u8)
    end

    # Reads the integer whose first octet is `block[position]`. Returns the
    # value and the position after it. Raises `TruncatedBlockError` when
    # the block ends inside it and `IntegerOverflowError` when it uses more
    # than `MAX_CONTINUATION_OCTETS` continuation octets or passes
    # `MAX_INTEGER`.
    def self.decode(block : Bytes, position : Int32, prefix : Int32) : {Int64, Int32}
      if position >= block.size
        raise TruncatedBlockError.new("Header block ends before an integer", Core::Position.new(position.to_i64))
      end
      mask = (1 << prefix) - 1
      value = (block.to_unsafe[position] & mask).to_i64
      position += 1
      return {value, position} if value < mask
      shift = 0
      MAX_CONTINUATION_OCTETS.times do
        if position >= block.size
          raise TruncatedBlockError.new("Header block ends inside an integer", Core::Position.new(position.to_i64))
        end
        byte = block.to_unsafe[position]
        position += 1
        value += (byte & 0x7f).to_i64 << shift
        if value > MAX_INTEGER
          raise IntegerOverflowError.new("Integer is over #{MAX_INTEGER}", Core::Position.new((position - 1).to_i64))
        end
        return {value, position} if byte < 0x80
        shift += 7
      end
      raise IntegerOverflowError.new("Integer has more than #{MAX_CONTINUATION_OCTETS} continuation octets",
        Core::Position.new(position.to_i64))
    end

    private def self.check_prefix(prefix : Int32) : Nil
      raise ArgumentError.new("prefix must be between 1 and 8 bits") unless 1 <= prefix <= 8
    end
  end
end
