module Mica::Core
  # Byte-run scanning for the hot loops of format scanners (text runs,
  # attribute values, names).
  #
  # This is the one place in Mica that reads bytes without a bounds check
  # on every read: each method checks its whole window against the slice
  # once, before its loop, and the loop index never leaves that window.
  # Everything else reads through checked `Slice` indexing.
  module ByteScan
    # Returns the index of the first byte in `bytes[from...stop]` for which
    # the block returns false, or *stop* when it returns true for all of
    # them. Raises `IndexError` unless `0 <= from <= stop <= bytes.size`.
    #
    # ```
    # Mica::Core::ByteScan.skip_while("abc;d".to_slice, 0, 5) { |byte| byte != ';'.ord } # => 3
    # ```
    @[AlwaysInline]
    def self.skip_while(bytes : Bytes, from : Int32, stop : Int32, & : UInt8 -> Bool) : Int32
      unless 0 <= from && from <= stop && stop <= bytes.size
        raise IndexError.new("Scan window #{from}...#{stop} is outside 0...#{bytes.size}")
      end
      index = from
      # from <= index < stop <= bytes.size, so every read is in bounds.
      while index < stop && yield bytes.unsafe_fetch(index)
        index += 1
      end
      index
    end

    # Returns true when the `expected.size` bytes of *bytes* at *offset*
    # equal *expected*. Raises `IndexError` unless
    # `0 <= offset <= bytes.size - expected.size`. Compares in place, which
    # beats building a slice and calling memcmp for short names.
    #
    # ```
    # Mica::Core::ByteScan.matches?("<a></a>".to_slice, 5, "a".to_slice) # => true
    # ```
    @[AlwaysInline]
    def self.matches?(bytes : Bytes, offset : Int32, expected : Bytes) : Bool
      size = expected.size
      unless 0 <= offset && offset <= bytes.size - size
        raise IndexError.new("Window #{offset}...#{offset + size} is outside 0...#{bytes.size}")
      end
      index = 0
      # 0 <= index < size, offset + size <= bytes.size: both reads in bounds.
      while index < size
        return false unless bytes.unsafe_fetch(offset + index) == expected.unsafe_fetch(index)
        index += 1
      end
      true
    end
  end
end
