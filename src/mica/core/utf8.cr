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
      decode(bytes, 0, bytes.size)
    end

    # Decodes the sequence at *offset* in *bytes*, reading no byte at or
    # past *limit* (at most `bytes.size`). Scanners call this form on their
    # hot path with their buffer, position and fill level; every read is
    # bounds-checked.
    def self.decode(bytes : Bytes, offset : Int32, limit : Int32) : {Int32, Int32}
      return {Problem::Truncated.value, 0} if offset >= limit
      b0 = bytes[offset].to_i32
      return {b0, 1} if b0 < 0x80
      return {Problem::UnexpectedContinuation.value, 0} if b0 < 0xC0
      return {Problem::Overlong.value, 0} if b0 < 0xC2
      return {Problem::InvalidLeadByte.value, 0} if b0 >= 0xF8
      length = b0 < 0xE0 ? 2 : (b0 < 0xF0 ? 3 : 4)
      # Report a bad continuation before truncation, so the verdict for a
      # prefix never depends on how many bytes follow it.
      index = 1
      while index < length
        return {Problem::Truncated.value, 0} if offset + index >= limit
        return {Problem::BadContinuation.value, 0} unless bytes[offset + index] & 0xC0 == 0x80
        index += 1
      end
      b1 = bytes[offset + 1].to_i32 & 0x3F
      case length
      when 2
        {((b0 & 0x1F) << 6) | b1, 2}
      when 3
        code = ((b0 & 0x0F) << 12) | (b1 << 6) | (bytes[offset + 2].to_i32 & 0x3F)
        return {Problem::Overlong.value, 0} if code < 0x800
        return {Problem::Surrogate.value, 0} if code >= 0xD800 && code <= 0xDFFF
        {code, 3}
      else
        code = ((b0 & 0x07) << 18) | (b1 << 12) | ((bytes[offset + 2].to_i32 & 0x3F) << 6) | (bytes[offset + 3].to_i32 & 0x3F)
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

    # Returns the offset of the first invalid sequence in *bytes* (its lead
    # byte, as `decode` reports it), or nil when all of it is valid UTF-8.
    #
    # Runs in one pass: the ASCII prefix eight bytes at a time, then runs
    # of ASCII sixteen bytes at a time and everything else through the
    # shift DFA below, one table read per byte and a check
    # for the error state every sixteen bytes, so text in any script
    # validates at the same speed.
    def self.first_invalid_offset(bytes : Bytes) : Int32?
      size = bytes.size
      pointer = bytes.to_unsafe
      # The ASCII prefix, eight bytes then one at a time: a haystack that
      # is all ASCII (the common case) never reaches the DFA.
      index = 0
      while index + 8 <= size && (pointer + index).as(UInt64*).value & 0x8080808080808080_u64 == 0
        index += 8
      end
      while index < size && pointer[index] < 0x80
        index += 1
      end
      return nil if index == size
      table = VALIDATION_TABLE
      state = ACCEPT_SHIFT
      lead = index
      while index < size
        if state == ACCEPT_SHIFT && index + 16 <= size &&
           ((pointer + index).as(UInt64*).value | (pointer + index + 8).as(UInt64*).value) & 0x8080808080808080_u64 == 0
          index += 16
          next
        end
        stop = Math.min(index + 16, size)
        while index < stop
          lead = index if state == ACCEPT_SHIFT
          state = (table.unsafe_fetch(pointer[index]) >> state) & 63
          index += 1
        end
        return lead if state == ERROR_SHIFT
      end
      state == ACCEPT_SHIFT ? nil : lead
    end

    # The states of the validation DFA: the error state, between sequences
    # (accept), and the bytes still owed by the sequence being read, with
    # the four leads whose second byte has a narrower range (E0 rules out
    # overlong forms, ED surrogates, F0 overlong forms, F4 code points
    # above U+10FFFF).
    private enum ValidationState
      Error
      Accept
      OneMore
      TwoMore
      ThreeMore
      AfterE0
      AfterED
      AfterF0
      AfterF4
    end

    # A state is stored as its shift: six bits per state, so the nine fit
    # one 64-bit row.
    private ERROR_SHIFT  = ValidationState::Error.value.to_u64 * 6
    private ACCEPT_SHIFT = ValidationState::Accept.value.to_u64 * 6

    # One row per byte value: for each state, the shift of the state that
    # byte leads to, at bit `6 × state` ("shift DFA": the next state is
    # `(row >> state) & 63`).
    private VALIDATION_TABLE = begin
      table = StaticArray(UInt64, 256).new(0_u64)
      256.times do |byte|
        row = 0_u64
        ValidationState.each do |state|
          row |= (validation_step(state, byte).value.to_u64 * 6) << (state.value * 6)
        end
        table[byte] = row
      end
      table
    end

    # The state after *byte* in *state* (`decode`'s rules).
    private def self.validation_step(state : ValidationState, byte : Int32) : ValidationState
      continuation = 0x80 <= byte <= 0xBF
      case state
      when .accept?
        return ValidationState::Accept if byte < 0x80
        return ValidationState::Error if byte < 0xC2
        return ValidationState::OneMore if byte < 0xE0
        return ValidationState::AfterE0 if byte == 0xE0
        return ValidationState::AfterED if byte == 0xED
        return ValidationState::TwoMore if byte < 0xF0
        return ValidationState::AfterF0 if byte == 0xF0
        return ValidationState::ThreeMore if byte < 0xF4
        return ValidationState::AfterF4 if byte == 0xF4
        ValidationState::Error
      when .one_more?   then continuation ? ValidationState::Accept : ValidationState::Error
      when .two_more?   then continuation ? ValidationState::OneMore : ValidationState::Error
      when .three_more? then continuation ? ValidationState::TwoMore : ValidationState::Error
      when .after_e0?   then 0xA0 <= byte <= 0xBF ? ValidationState::OneMore : ValidationState::Error
      when .after_ed?   then 0x80 <= byte <= 0x9F ? ValidationState::OneMore : ValidationState::Error
      when .after_f0?   then 0x90 <= byte <= 0xBF ? ValidationState::TwoMore : ValidationState::Error
      when .after_f4?   then 0x80 <= byte <= 0x8F ? ValidationState::TwoMore : ValidationState::Error
      else                   ValidationState::Error
      end
    end
  end
end
