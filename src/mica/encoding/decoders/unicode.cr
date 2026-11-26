require "../words"

module Mica::Encoding
  abstract class Decoder
    # Ends a call: counts the consumed bytes into `position`.
    protected def finish_call(status : Status, read : Int32, written : Int32) : Result
      @position += read
      Result.new(status, read, written)
    end

    # Ends a call on a fatal problem.
    protected def finish_with_problem(problem : Problem, offset : Int64, read : Int32, written : Int32) : Result
      @position += read
      Result.new(Status::Error, read, written, problem, offset)
    end

    # Handles a problem at *offset* in the current error mode: returns
    # from `convert` in `ErrorMode::Fatal` (after `reset`), writes U+FFFD
    # in `ErrorMode::Replacement`, writes nothing in `ErrorMode::Skip`.
    # Expects locals `read`, `written` and `output`.
    private macro handle_problem(problem, offset)
      if @error_mode.fatal?
        %offset = {{ offset }}
        reset
        return finish_with_problem({{ problem }}, %offset, read, written)
      elsif @error_mode.replacement?
        written = emit(output, written, 0xFFFD)
      end
    end
  end

  # UTF-8, validating: the Encoding Standard's UTF-8 decoder, which
  # replaces each maximal subpart of an ill-formed sequence with one
  # U+FFFD (Unicode chapter 3, Table 3-8).
  class UTF8Decoder < Decoder
    @code_point = 0
    @seen = 0
    @needed = 0
    @lower = 0x80
    @upper = 0xBF
    @sequence_start = 0_i64
    @bom_pending : Bool

    def initialize(codec : Codec, error_mode : ErrorMode, @strip_bom : Bool)
      super(codec, error_mode)
      @bom_pending = @strip_bom
    end

    def reset : Nil
      clear_sequence
      @bom_pending = @strip_bom
    end

    def convert(input : Bytes, output : Bytes, last : Bool) : Result
      check_output(output)
      read = 0
      written = 0
      size = input.size
      limit = output.size - 4
      while read < size
        return finish_call(Status::OutputFull, read, written) if written > limit
        byte = input.unsafe_fetch(read).to_i32
        if @needed == 0
          if byte < 0x80
            @bom_pending = false
            output.unsafe_put(written, byte.to_u8!)
            written += 1
            read += 1
            # Copy the rest of an ASCII run without the state checks.
            room = output.size
            while read < size && written < room
              next_byte = input.unsafe_fetch(read)
              break if next_byte >= 0x80
              output.unsafe_put(written, next_byte)
              written += 1
              read += 1
            end
            next
          end
          @sequence_start = @position + read
          read += 1
          if byte >= 0xC2 && byte <= 0xDF
            @needed = 1
            @code_point = byte & 0x1F
          elsif byte >= 0xE0 && byte <= 0xEF
            @lower = 0xA0 if byte == 0xE0
            @upper = 0x9F if byte == 0xED
            @needed = 2
            @code_point = byte & 0xF
          elsif byte >= 0xF0 && byte <= 0xF4
            @lower = 0x90 if byte == 0xF0
            @upper = 0x8F if byte == 0xF4
            @needed = 3
            @code_point = byte & 0x7
          else
            handle_problem(Problem::InvalidSequence, @sequence_start)
          end
          next
        end
        if byte < @lower || byte > @upper
          # The byte is not consumed: it may begin the next sequence.
          clear_sequence
          handle_problem(Problem::InvalidSequence, @sequence_start)
          next
        end
        read += 1
        @lower = 0x80
        @upper = 0xBF
        @code_point = (@code_point << 6) | (byte & 0x3F)
        @seen += 1
        next unless @seen == @needed
        code_point = @code_point
        clear_sequence
        written = emit(output, written, code_point)
      end
      if last && @needed != 0
        return finish_call(Status::OutputFull, read, written) if written > limit
        clear_sequence
        handle_problem(Problem::IncompleteSequence, @sequence_start)
      end
      finish_call(Status::InputEmpty, read, written)
    end

    private def clear_sequence : Nil
      @code_point = 0
      @seen = 0
      @needed = 0
      @lower = 0x80
      @upper = 0xBF
    end

    @[AlwaysInline]
    private def emit(output : Bytes, written : Int32, code_point : Int32) : Int32
      if @bom_pending
        @bom_pending = false
        return written if code_point == 0xFEFF
      end
      Encoding.put_utf8(output, written, code_point)
    end
  end

  # UTF-16 in either byte order (the Encoding Standard's shared UTF-16
  # decoder), plus the iconv forms: `UTF-16` reads a byte order mark
  # (little-endian without one, as glibc) and UCS-2 treats every surrogate code unit as
  # an error.
  class UTF16Decoder < Decoder
    @lead_byte = -1
    @lead_surrogate = -1
    @sequence_start = 0_i64
    @bom_pending : Bool
    @detect_bom : Bool
    @ucs2 : Bool

    def initialize(codec : Codec, error_mode : ErrorMode, *, big_endian : Bool, @strip_bom : Bool)
      super(codec, error_mode)
      @big_endian = big_endian
      @initial_big_endian = big_endian
      @detect_bom = codec.utf16?
      @ucs2 = codec.ucs2? || codec.ucs2_be? || codec.ucs2_le?
      @bom_pending = @strip_bom
    end

    def reset : Nil
      @lead_byte = -1
      @lead_surrogate = -1
      @big_endian = @initial_big_endian
      @detect_bom = @codec.utf16?
      @bom_pending = @strip_bom
    end

    def convert(input : Bytes, output : Bytes, last : Bool) : Result
      check_output(output)
      read = 0
      written = 0
      size = input.size
      limit = output.size - 8
      while read < size
        return finish_call(Status::OutputFull, read, written) if written > limit
        if @lead_byte < 0 && @lead_surrogate < 0 && !@detect_bom && !@bom_pending
          before = read
          read, written = decode_units(input, read, output, written)
          next if read != before
        end
        byte = input.unsafe_fetch(read).to_i32
        if @lead_byte < 0
          @sequence_start = @position + read if @lead_surrogate < 0
          @lead_byte = byte
          read += 1
          next
        end
        lead_byte = @lead_byte
        unit = @big_endian ? (lead_byte << 8) | byte : (byte << 8) | lead_byte
        @lead_byte = -1
        read += 1
        if @detect_bom
          @detect_bom = false
          next if unit == 0xFEFF
          if unit == 0xFFFE
            @big_endian = !@big_endian
            next
          end
        end
        if @ucs2
          if unit >= 0xD800 && unit <= 0xDFFF
            handle_problem(Problem::InvalidSequence, @sequence_start)
          else
            written = emit(output, written, unit)
          end
          next
        end
        if (lead = @lead_surrogate) >= 0
          @lead_surrogate = -1
          if unit >= 0xDC00 && unit <= 0xDFFF
            written = emit(output, written, 0x10000 + ((lead - 0xD800) << 10) + (unit - 0xDC00))
            next
          end
          # An unpaired leading surrogate. The code unit after it is
          # restored and read again on its own.
          if @error_mode.fatal?
            offset = @sequence_start
            reset
            if read >= 2
              read -= 2
            else
              # Its first byte came in an earlier call: keep it pending,
              # starting a sequence at that byte (the last one consumed
              # before this call), as when the unit is read again whole.
              read -= 1
              @lead_byte = lead_byte
              @sequence_start = @position - 1
            end
            return finish_with_problem(Problem::InvalidSequence, offset, read, written)
          end
          written = emit(output, written, 0xFFFD) if @error_mode.replacement?
          @sequence_start = @position + read - 2
        end
        if unit >= 0xD800 && unit <= 0xDBFF
          @lead_surrogate = unit
        elsif unit >= 0xDC00 && unit <= 0xDFFF
          handle_problem(Problem::InvalidSequence, @sequence_start)
        else
          written = emit(output, written, unit)
        end
      end
      if last && (@lead_byte >= 0 || @lead_surrogate >= 0)
        return finish_call(Status::OutputFull, read, written) if written > limit
        @lead_byte = -1
        @lead_surrogate = -1
        handle_problem(Problem::IncompleteSequence, @sequence_start)
      end
      finish_call(Status::InputEmpty, read, written)
    end

    # Decodes whole code units from *input* at *read* into *output* at
    # *written* while nothing is pending, and returns where both stopped.
    # Four ASCII units are narrowed per step. It stops before any unit it
    # cannot finish on its own (a surrogate that is lone, split by the end
    # of the input, or in UCS-2) and when fewer than 4 bytes of output room
    # remain, leaving that unit to the per-byte loop in `convert`.
    private def decode_units(input : Bytes, read : Int32, output : Bytes, written : Int32) : {Int32, Int32}
      big_endian = @big_endian
      ucs2 = @ucs2
      size = input.size
      room = output.size - 4
      # Four units write at most 12 bytes, and the last store 3 more.
      word_room = output.size - 16
      source = input.to_unsafe
      target = output.to_unsafe
      while read &+ 2 <= size && written <= room
        if read &+ 8 <= size && written <= word_room
          word = Encoding.load_u64_le(source + read)
          word = Encoding.swap_bytes_in_units(word) if big_endian
          # Eight ASCII units at a time. Mixed text seldom passes this
          # test, so the branch stays predictable either way.
          if read &+ 16 <= size
            next_word = Encoding.load_u64_le(source + read + 8)
            next_word = Encoding.swap_bytes_in_units(next_word) if big_endian
            if (word | next_word) & 0xFF80FF80FF80FF80_u64 == 0
              Encoding.store_u32_le(target + written, Encoding.narrow_units(word))
              Encoding.store_u32_le(target + written + 4, Encoding.narrow_units(next_word))
              read &+= 16
              written &+= 8
              next
            end
          elsif word & 0xFF80FF80FF80FF80_u64 == 0
            Encoding.store_u32_le(target + written, Encoding.narrow_units(word))
            read &+= 8
            written &+= 4
            next
          end
          # Mixed text: the ASCII units before the first other one (at
          # most three) are narrowed together, then that unit is written
          # without branching on its UTF-8 length. Nothing here branches
          # on the text except a surrogate, which the per-unit step below
          # takes.
          non_ascii = word & 0xFF80FF80FF80FF80_u64
          ascii_units = Math.min(non_ascii.trailing_zeros_count.to_i32! // 16, 3)
          Encoding.store_u32_le(target + written, Encoding.narrow_units(word))
          read &+= ascii_units &* 2
          written &+= ascii_units
          unit = (word.unsafe_shr(ascii_units &* 16) & 0xFFFF).to_i32!
          unless unit & 0xF800 == 0xD800
            written = Encoding.put_bmp_utf8(target, written, unit)
            read &+= 2
            next
          end
        end
        first = source[read].to_i32
        second = source[read + 1].to_i32
        unit = big_endian ? (first << 8) | second : (second << 8) | first
        if unit < 0x80
          target[written] = unit.to_u8!
          written &+= 1
          read &+= 2
        elsif unit < 0xD800 || unit > 0xDFFF
          written = Encoding.put_utf8(output, written, unit)
          read &+= 2
        else
          break if ucs2 || unit > 0xDBFF || read &+ 4 > size
          first = source[read + 2].to_i32
          second = source[read + 3].to_i32
          trail = big_endian ? (first << 8) | second : (second << 8) | first
          break unless trail >= 0xDC00 && trail <= 0xDFFF
          written = Encoding.put_utf8(output, written, 0x10000 + ((unit - 0xD800) << 10) + (trail - 0xDC00))
          read &+= 4
        end
      end
      {read, written}
    end

    @[AlwaysInline]
    private def emit(output : Bytes, written : Int32, code_point : Int32) : Int32
      if @bom_pending
        @bom_pending = false
        return written if code_point == 0xFEFF
      end
      Encoding.put_utf8(output, written, code_point)
    end
  end

  # UTF-32 in either byte order; `UTF-32` reads a byte order mark
  # (little-endian without one, as glibc). A value above U+10FFFF or a surrogate is an
  # error covering its four bytes.
  class UTF32Decoder < Decoder
    @unit = 0_u32
    @count = 0
    @sequence_start = 0_i64
    @detect_bom : Bool
    @big_endian : Bool

    def initialize(codec : Codec, error_mode : ErrorMode)
      super(codec, error_mode)
      @detect_bom = codec.utf32?
      @big_endian = codec.utf32_be?
    end

    def reset : Nil
      @unit = 0_u32
      @count = 0
      @detect_bom = @codec.utf32?
      @big_endian = @codec.utf32_be?
    end

    def convert(input : Bytes, output : Bytes, last : Bool) : Result
      check_output(output)
      read = 0
      written = 0
      size = input.size
      limit = output.size - 4
      while read < size
        return finish_call(Status::OutputFull, read, written) if written > limit
        byte = input.unsafe_fetch(read).to_u32
        @sequence_start = @position + read if @count == 0
        read += 1
        if @big_endian
          @unit = (@unit << 8) | byte
        else
          @unit |= byte << (8 * @count)
        end
        @count += 1
        next unless @count == 4
        unit = @unit
        @unit = 0_u32
        @count = 0
        if @detect_bom
          @detect_bom = false
          next if unit == 0x0000FEFF_u32
          if unit == 0xFFFE0000_u32
            @big_endian = !@big_endian
            next
          end
        end
        if unit > 0x10FFFF_u32 || (unit >= 0xD800_u32 && unit <= 0xDFFF_u32)
          handle_problem(Problem::InvalidSequence, @sequence_start)
        else
          written = emit(output, written, unit.to_i32)
        end
      end
      if last && @count != 0
        return finish_call(Status::OutputFull, read, written) if written > limit
        @unit = 0_u32
        @count = 0
        handle_problem(Problem::IncompleteSequence, @sequence_start)
      end
      finish_call(Status::InputEmpty, read, written)
    end

    @[AlwaysInline]
    private def emit(output : Bytes, written : Int32, code_point : Int32) : Int32
      Encoding.put_utf8(output, written, code_point)
    end
  end

  # Every single-byte encoding: bytes below 0x80 are ASCII and the others
  # come from a 128-entry table (index single-byte, exact ISO-8859-1,
  # x-user-defined, or US-ASCII's empty one).
  class SingleByteDecoder < Decoder
    @table : Slice(UInt16)

    def initialize(codec : Codec, error_mode : ErrorMode)
      super(codec, error_mode)
      @table = Tables.single_byte(codec)
    end

    def reset : Nil
    end

    def convert(input : Bytes, output : Bytes, last : Bool) : Result
      check_output(output)
      read = 0
      written = 0
      size = input.size
      limit = output.size - 3
      table = @table
      while read < size
        return finish_call(Status::OutputFull, read, written) if written > limit
        byte = input.unsafe_fetch(read)
        read += 1
        if byte < 0x80
          output.unsafe_put(written, byte)
          written += 1
          next
        end
        code_point = table.unsafe_fetch(byte - 0x80).to_i32
        if code_point == 0
          handle_problem(Problem::InvalidSequence, @position + read - 1)
        else
          written = Encoding.put_utf8(output, written, code_point)
        end
      end
      finish_call(Status::InputEmpty, read, written)
    end

    @[AlwaysInline]
    private def emit(output : Bytes, written : Int32, code_point : Int32) : Int32
      Encoding.put_utf8(output, written, code_point)
    end
  end
end
