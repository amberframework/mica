module Mica
  # :nodoc:
  #
  # Read-only IO that transcodes UTF-16 (big or little endian) from *source*
  # into UTF-8. Invalid input (an unpaired surrogate or an odd trailing byte)
  # is emitted as the byte 0xFF, which is never valid UTF-8, so the scanner
  # reports it as an encoding error at the exact position where it occurs.
  class UTF16Decoder < IO
    INVALID_BYTE = 0xFF_u8

    @input : Bytes
    @input_start = 0
    @input_end = 0
    @pending_high = -1
    @eof = false

    def initialize(@source : IO, @big_endian : Bool, prefix : Bytes = Bytes.empty)
      @input = Bytes.new(Math.max(16 * 1024, prefix.size + 2))
      prefix.copy_to(@input)
      @input_end = prefix.size
    end

    # Fills *slice* with UTF-8. *slice* must have room for at least four
    # bytes (one encoded code point); the scanner always reads in larger
    # chunks.
    def read(slice : Bytes) : Int32
      written = 0
      while written + 4 <= slice.size
        if @input_end - @input_start < 2
          refill
          if @input_end - @input_start < 2
            written = finish(slice, written)
            break
          end
        end
        written = decode_unit(read_unit, slice, written)
      end
      written
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("UTF16Decoder is read-only")
    end

    private def read_unit : Int32
      b0 = @input[@input_start].to_i32
      b1 = @input[@input_start + 1].to_i32
      @input_start += 2
      @big_endian ? (b0 << 8) | b1 : (b1 << 8) | b0
    end

    private def decode_unit(unit : Int32, slice : Bytes, written : Int32) : Int32
      if unit >= 0xD800 && unit <= 0xDBFF
        written = flush_unpaired(slice, written)
        @pending_high = unit
        return written
      end
      if unit >= 0xDC00 && unit <= 0xDFFF
        high = @pending_high
        if high < 0
          slice[written] = INVALID_BYTE
          return written + 1
        end
        @pending_high = -1
        code = 0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00)
        return encode(code, slice, written)
      end
      written = flush_unpaired(slice, written)
      encode(unit, slice, written)
    end

    private def flush_unpaired(slice : Bytes, written : Int32) : Int32
      return written if @pending_high < 0
      @pending_high = -1
      slice[written] = INVALID_BYTE
      written + 1
    end

    # Handles end of input: a dangling high surrogate or odd byte becomes
    # the invalid marker byte.
    private def finish(slice : Bytes, written : Int32) : Int32
      written = flush_unpaired(slice, written)
      if @input_end - @input_start == 1
        @input_start += 1
        slice[written] = INVALID_BYTE
        written += 1
      end
      written
    end

    private def encode(code : Int32, slice : Bytes, written : Int32) : Int32
      if code < 0x80
        slice[written] = code.to_u8
        written + 1
      elsif code < 0x800
        slice[written] = (0xC0 | (code >> 6)).to_u8
        slice[written + 1] = (0x80 | (code & 0x3F)).to_u8
        written + 2
      elsif code < 0x10000
        slice[written] = (0xE0 | (code >> 12)).to_u8
        slice[written + 1] = (0x80 | ((code >> 6) & 0x3F)).to_u8
        slice[written + 2] = (0x80 | (code & 0x3F)).to_u8
        written + 3
      else
        slice[written] = (0xF0 | (code >> 18)).to_u8
        slice[written + 1] = (0x80 | ((code >> 12) & 0x3F)).to_u8
        slice[written + 2] = (0x80 | ((code >> 6) & 0x3F)).to_u8
        slice[written + 3] = (0x80 | (code & 0x3F)).to_u8
        written + 4
      end
    end

    private def refill : Nil
      return if @eof
      remaining = @input_end - @input_start
      @input.copy_from(@input.to_unsafe + @input_start, remaining) if remaining > 0
      @input_start = 0
      @input_end = remaining
      while @input_end < 2
        count = @source.read(@input[@input_end, @input.size - @input_end])
        if count == 0
          @eof = true
          return
        end
        @input_end += count
      end
    end
  end
end
