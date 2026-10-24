module Mica::Core
  # UTF-8 decoding and encoding (RFC 3629), shared by every text format.
  #
  # Decoding is strict: overlong forms, encoded surrogates (U+D800 to
  # U+DFFF), code points above U+10FFFF, the retired 5- and 6-byte forms
  # (lead bytes F8 to FD), FE and FF, stray continuation bytes and
  # truncated sequences are all rejected. Nothing is ever replaced with
  # U+FFFD.
  module UTF8
    # Why a sequence failed to decode, from `decode`.
    enum Problem
      # Fewer bytes are available than the lead byte announces.
      Truncated
      # A continuation byte (80 to BF) where a lead byte belongs.
      UnexpectedContinuation
      # A lead byte C0 or C1, or a longer sequence that encodes a code
      # point a shorter one could.
      Overlong
      # A 3-byte sequence encoding U+D800 to U+DFFF.
      Surrogate
      # A 4-byte sequence above U+10FFFF (lead bytes F4 with a high
      # second byte, F5 to F7).
      OutOfRange
      # A 5- or 6-byte lead byte (F8 to FD), or FE or FF.
      InvalidLeadByte
      # A lead byte followed by a byte that is not a continuation byte.
      BadContinuation

      def describe : String
        case self
        in .truncated?               then "truncated UTF-8 sequence"
        in .unexpected_continuation? then "UTF-8 continuation byte without a lead byte"
        in .overlong?                then "overlong UTF-8 encoding"
        in .surrogate?               then "UTF-8 encoding of a UTF-16 surrogate"
        in .out_of_range?            then "UTF-8 sequence above U+10FFFF"
        in .invalid_lead_byte?       then "byte that never appears in UTF-8"
        in .bad_continuation?        then "UTF-8 sequence with a missing continuation byte"
        end
      end
    end

    # Returns the number of bytes the sequence led by *lead* occupies:
    # 1 for ASCII and for bytes that cannot lead a sequence.
    @[AlwaysInline]
    def self.sequence_length(lead : UInt8) : Int32
      if lead < 0xC0
        1
      elsif lead < 0xE0
        2
      elsif lead < 0xF0
        3
      else
        4
      end
    end

    # Decodes the sequence at the start of *bytes*. Returns
    # `{code_point, byte_length}`; on failure the length is 0 and the code
    # point is the `Problem` value.
    #
    # ```
    # Mica::Core::UTF8.decode("é".to_slice)      # => {233, 2}
    # Mica::Core::UTF8.decode(Bytes[0xC0, 0x80]) # => {2, 0} (Problem::Overlong)
    # ```
    def self.decode(bytes : Bytes) : {Int32, Int32}
      return {Problem::Truncated.value, 0} if bytes.empty?
      decode(bytes.to_unsafe, bytes.size)
    end

    # :nodoc:
    #
    # Pointer form used by scanners on their hot path. *available* must be
    # at least 1 and no more than the bytes readable at *ptr*; the function
    # reads `ptr[0]` to `ptr[available - 1]` at most.
    def self.decode(ptr : UInt8*, available : Int32) : {Int32, Int32}
      b0 = ptr[0].to_i32
      return {b0, 1} if b0 < 0x80
      return {Problem::UnexpectedContinuation.value, 0} if b0 < 0xC0
      return {Problem::Overlong.value, 0} if b0 < 0xC2
      return {Problem::InvalidLeadByte.value, 0} if b0 >= 0xF8
      length = b0 < 0xE0 ? 2 : (b0 < 0xF0 ? 3 : 4)
      # Report a bad continuation before truncation, so the verdict for a
      # prefix never depends on how many bytes follow it.
      index = 1
      while index < length
        return {Problem::Truncated.value, 0} if index >= available
        return {Problem::BadContinuation.value, 0} unless ptr[index] & 0xC0 == 0x80
        index += 1
      end
      case length
      when 2
        {((b0 & 0x1F) << 6) | (ptr[1].to_i32 & 0x3F), 2}
      when 3
        code = ((b0 & 0x0F) << 12) | ((ptr[1].to_i32 & 0x3F) << 6) | (ptr[2].to_i32 & 0x3F)
        return {Problem::Overlong.value, 0} if code < 0x800
        return {Problem::Surrogate.value, 0} if code >= 0xD800 && code <= 0xDFFF
        {code, 3}
      else
        code = ((b0 & 0x07) << 18) | ((ptr[1].to_i32 & 0x3F) << 12) | ((ptr[2].to_i32 & 0x3F) << 6) | (ptr[3].to_i32 & 0x3F)
        return {Problem::Overlong.value, 0} if code < 0x10000
        return {Problem::OutOfRange.value, 0} if code > 0x10FFFF
        {code, 4}
      end
    end

    # Returns the problem for a failed `decode` result.
    def self.problem(code : Int32) : Problem
      Problem.from_value(code)
    end

    # Returns the number of bytes `encode` writes for *code*.
    @[AlwaysInline]
    def self.encoded_size(code : Int32) : Int32
      if code < 0x80
        1
      elsif code < 0x800
        2
      elsif code < 0x10000
        3
      else
        4
      end
    end

    # Writes the UTF-8 encoding of *code* (a scalar value) at the start of
    # *target*, which must have room for `encoded_size(code)` bytes. Returns
    # the number of bytes written.
    def self.encode(code : Int32, target : Bytes) : Int32
      size = encoded_size(code)
      raise ArgumentError.new("UTF-8 target too small") if target.size < size
      case size
      when 1
        target[0] = code.to_u8
      when 2
        target[0] = (0xC0 | (code >> 6)).to_u8
        target[1] = (0x80 | (code & 0x3F)).to_u8
      when 3
        target[0] = (0xE0 | (code >> 12)).to_u8
        target[1] = (0x80 | ((code >> 6) & 0x3F)).to_u8
        target[2] = (0x80 | (code & 0x3F)).to_u8
      else
        target[0] = (0xF0 | (code >> 18)).to_u8
        target[1] = (0x80 | ((code >> 12) & 0x3F)).to_u8
        target[2] = (0x80 | ((code >> 6) & 0x3F)).to_u8
        target[3] = (0x80 | (code & 0x3F)).to_u8
      end
      size
    end

    # Returns the offset of the first invalid sequence in *bytes*, or nil
    # when all of it is valid UTF-8. Runs in one pass.
    def self.first_invalid_offset(bytes : Bytes) : Int32?
      index = 0
      size = bytes.size
      ptr = bytes.to_unsafe
      while index < size
        if ptr[index] < 0x80
          index += 1
          next
        end
        _, length = decode(ptr + index, size - index)
        return index if length == 0
        index += length
      end
      nil
    end
  end
end
