module Mica::Encoding
  # The byte loop shared by the legacy multi-byte decoders, which are
  # written as the Encoding Standard writes them: a handler that takes one
  # byte (or the end of the queue) and returns a code point, CONTINUE,
  # ERROR or FINISHED, and may restore the last bytes it consumed to the
  # front of the queue. Including it gives the decoder `convert`.
  #
  # The including class implements `step(byte : Int32) : Int32`,
  # `idle? : Bool` (no sequence open) and `clear_state`.
  module LegacyByteLoop
    END_OF_QUEUE = -1
    CONTINUE     = -1
    ERROR        = -2
    FINISHED     = -3

    # Restored bytes waiting to be read before the next input byte, with
    # their offsets in the source; at most four are ever held.
    @pending = StaticArray(UInt8, 8).new(0_u8)
    @pending_offsets = StaticArray(Int64, 8).new(0_i64)
    @pending_size = 0
    # Offset of the byte `step` is handling; restored bytes count back
    # from it.
    @current_offset = 0_i64
    @sequence_start = 0_i64
    # A second code point from the last step (Big5's composed pairs).
    @extra_code_point = -1

    def reset : Nil
      clear_state
      @pending_size = 0
      @extra_code_point = -1
    end

    def convert(input : Bytes, output : Bytes, last : Bool) : Result
      check_output(output)
      read = 0
      written = 0
      size = input.size
      limit = output.size - 8
      loop do
        return finish_call(Status::OutputFull, read, written) if written > limit
        if @pending_size > 0
          byte = @pending[0].to_i32
          @current_offset = @pending_offsets[0]
          @pending_size -= 1
          @pending_size.times do |index|
            @pending[index] = @pending[index + 1]
            @pending_offsets[index] = @pending_offsets[index + 1]
          end
        elsif read < size
          if fast_path? && idle?
            started = read
            read, written = decode_fast_run(input, read, output, written, limit)
            next if read != started
          end
          byte = input.unsafe_fetch(read).to_i32
          @current_offset = @position + read
          read += 1
          if byte < 0x80 && ascii_passthrough?
            # An ASCII byte with no sequence open is itself.
            output.unsafe_put(written, byte.to_u8!)
            written += 1
            next
          end
        elsif last
          byte = END_OF_QUEUE
        else
          break
        end
        @sequence_start = @current_offset if byte != END_OF_QUEUE && idle?
        result = step(byte)
        if result >= 0
          written = Encoding.put_utf8(output, written, result)
          if (extra = @extra_code_point) >= 0
            @extra_code_point = -1
            written = Encoding.put_utf8(output, written, extra)
          end
        elsif result == FINISHED
          break
        elsif result == ERROR
          problem = byte == END_OF_QUEUE ? Problem::IncompleteSequence : Problem::InvalidSequence
          if @error_mode.fatal?
            offset = @sequence_start
            clear_state
            @extra_code_point = -1
            read = unconsume_restored(read)
            return finish_with_problem(problem, offset, read, written)
          elsif @error_mode.replacement?
            written = Encoding.put_utf8(output, written, 0xFFFD)
          end
        end
      end
      finish_call(Status::InputEmpty, read, written)
    end

    # Puts *bytes*, the last ones consumed (the current byte last), back at
    # the front of the queue.
    private def restore(*bytes : Int32) : Nil
      count = bytes.size
      @pending_size.downto(1) do |index|
        @pending[index - 1 + count] = @pending[index - 1]
        @pending_offsets[index - 1 + count] = @pending_offsets[index - 1]
      end
      bytes.each_with_index do |byte, index|
        @pending[index] = byte.to_u8!
        @pending_offsets[index] = @current_offset - (count - 1 - index)
      end
      @pending_size += count
    end

    # After a fatal error, restored bytes that came from this call's input
    # go back to the caller (not consumed); restored bytes from earlier
    # calls stay pending. Returns the corrected read count.
    private def unconsume_restored(read : Int32) : Int32
      kept = 0
      @pending_size.times do |index|
        offset = @pending_offsets[index]
        if offset < @position
          @pending[kept] = @pending[index]
          @pending_offsets[kept] = offset
          kept += 1
        else
          read = Math.min(read, (offset - @position).to_i32)
        end
      end
      @pending_size = kept
      read
    end

    # True when an ASCII input byte can be written straight out: no
    # sequence is open and nothing is pending. Decoders whose ASCII bytes
    # mean something else in some state (ISO-2022-JP) override it.
    @[AlwaysInline]
    private def ascii_passthrough? : Bool
      idle?
    end

    # True when `decode_fast_run` may run while no sequence is open.
    # Decoders with shift states (ISO-2022-JP) or no characters at all
    # (replacement) override it.
    @[AlwaysInline]
    private def fast_path? : Bool
      true
    end

    # Returns the UTF-8 of the two-byte character *leading*, *trailing*,
    # packed as `LegacyUTF8Index` packs it, when both bytes form a valid
    # character that `step` would decode the same way with no error and no
    # second code point; otherwise 0, and the bytes go through `step`.
    # *index* is the decoder's `utf8_index`.
    @[AlwaysInline]
    private def pair_utf8(index : Slice(UInt32), leading : Int32, trailing : Int32) : UInt32
      0_u32
    end

    # Returns the entry of *index* at *pointer* when *valid*, otherwise 0.
    # It reads entry 0 instead of branching, so the fast path can decode a
    # character without first asking whether it is ASCII; *pointer* need
    # only be in range when *valid*.
    @[AlwaysInline]
    private def entry(index : Slice(UInt32), valid : Bool, pointer : Int32) : UInt32
      packed = index.unsafe_fetch(valid ? pointer : 0)
      valid ? packed : 0_u32
    end

    # The packed UTF-8 index `pair_utf8` reads.
    @[AlwaysInline]
    private def utf8_index : Slice(UInt32)
      Slice(UInt32).empty
    end

    # Returns true when *low* <= *value* <= *high*, in one comparison.
    @[AlwaysInline]
    private def between?(value : Int32, low : Int32, high : Int32) : Bool
      (value &- low).to_u32! <= (high &- low).to_u32!
    end

    # The high bit of each of eight bytes.
    HIGH_BITS = 0x8080808080808080_u64

    # Input the block walk in `decode_fast_run` reads: sixty-four bytes
    # and the trail byte of a character that starts on the last of them.
    BLOCK_INPUT = 65

    # Output room the block walk needs: at most three bytes for each two
    # input bytes and one for each ASCII byte (at most 98 for 65 bytes),
    # the four bytes the last store touches, and some to spare.
    BLOCK_OUTPUT = 112

    # Returns the lead bytes among the non-ASCII bytes *wide* marks (bit i
    # for byte i): in each run of non-ASCII bytes the first, third, fifth
    # and so on lead, each with the byte after it as its trail, whatever
    # that byte is. Adding the run starts at even positions to *wide*
    # carries through exactly those runs, which tells them from the runs
    # that start at odd positions without walking the bytes in turn.
    @[AlwaysInline]
    private def lead_bytes(wide : UInt64) : UInt64
      starts = wide & ~(wide << 1)
      even_runs = wide & ~(wide &+ (starts & EVEN_BITS))
      odd_runs = wide ^ even_runs
      (even_runs & EVEN_BITS) | (odd_runs & ~EVEN_BITS)
    end

    # The even bit positions of a word.
    EVEN_BITS = 0x5555555555555555_u64

    # Returns a bit for each byte of *word* (as loaded in little-endian
    # order) whose high bit is set, byte i at bit i. The multiplication
    # gathers bit 0 of each byte into the top byte; no two of its partial
    # products overlap, so nothing carries.
    @[AlwaysInline]
    private def gather_high_bits(word : UInt64) : UInt64
      (((word & HIGH_BITS) >> 7) &* 0x0102040810204080_u64) >> 56
    end

    # Decodes from *read*, while no sequence is open and nothing is
    # pending, ASCII bytes and the two-byte characters
    # `pair_utf8` knows, and stops at the first byte it cannot handle so
    # that `step` sees it. Like the byte loop it takes a step only while
    # *written* is at most *limit*, so a call stops at the same place
    # either way. Returns the new read and written counts.
    @[AlwaysInline]
    private def decode_fast_run(input : Bytes, read : Int32, output : Bytes, written : Int32, limit : Int32) : {Int32, Int32}
      # Wrapping arithmetic throughout: 0 <= read <= size and
      # 0 <= written <= limit + 1 bound every sum, and *limit* leaves eight
      # bytes of room after *written*.
      source = input.to_unsafe
      target = output.to_unsafe
      size = input.size
      index = utf8_index
      # Sixty-four bytes at a time while there is room. Eight loads tell
      # which bytes are ASCII and which lead a pair, and then each
      # character is decoded without a branch on its kind: the next one
      # starts where that mask says, never waiting on a table read.
      while size &- read >= BLOCK_INPUT && limit &- written >= BLOCK_OUTPUT
        block = source + read
        # Bit i set: byte i of the block is not ASCII.
        wide = 0_u64
        8.times do |part|
          word = uninitialized UInt64
          pointerof(word).as(UInt8*).copy_from(block + part * 8, 8)
          word = word.byte_swap if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian
          wide |= gather_high_bits(word) << (part * 8)
        end
        if wide == 0
          (target + written).copy_from(block, 64)
          read &+= 64
          written &+= 64
          next
        end
        leads = lead_bytes(wide)
        # Every byte that is not a trail byte starts a character.
        starts = ~(leads << 1)
        while starts != 0
          position = starts.trailing_zeros_count.to_i32!
          starts &= starts &- 1
          leading = block[position].to_i32
          pair = pair_utf8(index, leading, block[position &+ 1].to_i32)
          packed = leads.unsafe_shr(position) & 1 == 0 ? leading.to_u32! | 0x01000000_u32 : pair
          return {read &+ position, written} if packed == 0
          written = write_packed(target, written, packed)
        end
        # A character that starts on the last byte ends past the block.
        read &+= 64 &+ (leads >> 63).to_i32!
      end
      loop do
        # No step writes more than two bytes per input byte, so before
        # *stop* every step starts with *written* at most *limit*, and a
        # lead byte always has its trail byte in the input.
        stop = Math.min(size &- 1, read &+ ((limit &- written &+ 1) >> 1))
        break if read >= stop
        while read < stop
          byte = source[read].to_i32
          if byte < 0x80
            if size &- read >= 8
              read, written = copy_ascii(source, read, target, written, limit)
            else
              target[written] = byte.to_u8!
              read &+= 1
              written &+= 1
            end
            next
          end
          packed = pair_utf8(index, byte, source[read &+ 1].to_i32)
          return {read, written} if packed == 0
          written = write_packed(target, written, packed)
          read &+= 2
        end
      end
      # The last input byte, or the last steps before *limit*.
      while read < size && written <= limit
        byte = source[read].to_i32
        if byte < 0x80
          target[written] = byte.to_u8!
          read &+= 1
          written &+= 1
          next
        end
        break if size &- read < 2
        packed = pair_utf8(index, byte, source[read &+ 1].to_i32)
        break if packed == 0
        written = write_packed(target, written, packed)
        read &+= 2
      end
      {read, written}
    end

    # Copies the ASCII bytes at *read* (at least eight remain, the first
    # is ASCII) eight at a time: it stores all eight, which always fit,
    # and counts only the leading ASCII ones, no more than the byte loop
    # would write before passing *limit*.
    @[AlwaysInline]
    private def copy_ascii(source : UInt8*, read : Int32, target : UInt8*, written : Int32, limit : Int32) : {Int32, Int32}
      word = uninitialized UInt64
      pointerof(word).as(UInt8*).copy_from(source + read, 8)
      (target + written).copy_from(pointerof(word).as(UInt8*), 8)
      high_bits = word & HIGH_BITS
      high_bits = high_bits.byte_swap if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian
      count = high_bits == 0 ? 8 : high_bits.trailing_zeros_count.to_i32! >> 3
      room = limit &- written &+ 1
      count = room if room < count
      {read &+ count, written &+ count}
    end

    # Writes the UTF-8 in *packed* at *offset* (four bytes are stored; the
    # count says how many belong) and returns the offset after it.
    @[AlwaysInline]
    private def write_packed(target : UInt8*, offset : Int32, packed : UInt32) : Int32
      bytes = IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian ? packed.byte_swap : packed
      (target + offset).copy_from(pointerof(bytes).as(UInt8*), 4)
      offset &+ (packed >> 24).to_i32!
    end
  end

  # The two-byte indexes with each entry already encoded as UTF-8, for
  # the decoders' fast path (`LegacyByteLoop#pair_utf8`). An entry holds
  # the UTF-8 bytes in its low three bytes, the first lowest, and their
  # count in its top byte; 0 stands for an empty pointer and for an astral
  # code point (Big5 HKSCS), which go through `step`. Each is built on
  # first use from its index in `Tables`, and covers every pointer its
  # decoders can compute, so a lookup needs no bounds check.
  module LegacyUTF8Index
    @@gb18030 : Slice(UInt32)? = nil
    @@big5 : Slice(UInt32)? = nil
    @@jis0208 : Slice(UInt32)? = nil
    @@euc_kr : Slice(UInt32)? = nil

    # Pointers (lead - 0x81) * 190 + trail offset, below 126 * 190.
    def self.gb18030 : Slice(UInt32)
      @@gb18030 ||= build(126 * 190) { |pointer| Tables.code_point(Tables::GB18030, pointer) }
    end

    # Pointers (lead - 0x81) * 157 + trail offset, below 126 * 157.
    def self.big5 : Slice(UInt32)
      @@big5 ||= build(126 * 157) { |pointer| Tables.code_point(Tables::BIG5, pointer) }
    end

    # Shift_JIS pointers, below 60 * 188, with the end-user-defined area
    # (8836 to 10715) mapped to the Private Use Area as Shift_JIS decodes
    # it. EUC-JP pointers are below 94 * 94, where the two agree.
    def self.jis0208 : Slice(UInt32)
      @@jis0208 ||= build(60 * 188) do |pointer|
        pointer >= 8836 && pointer <= 10715 ? 0xE000 - 8836 + pointer : Tables.code_point(Tables::JIS0208, pointer)
      end
    end

    # Pointers (lead - 0x81) * 190 + trail - 0x41, below 126 * 190.
    def self.euc_kr : Slice(UInt32)
      @@euc_kr ||= build(126 * 190) { |pointer| Tables.code_point(Tables::EUC_KR, pointer) }
    end

    private def self.build(size : Int32, & : Int32 -> Int32) : Slice(UInt32)
      bytes = Bytes.new(4)
      Slice(UInt32).new(size) do |pointer|
        code_point = yield pointer
        if code_point < 0 || code_point > 0xFFFF
          0_u32
        else
          count = Encoding.put_utf8(bytes, 0, code_point)
          bytes[0].to_u32 | (count > 1 ? bytes[1].to_u32 << 8 : 0_u32) | (count > 2 ? bytes[2].to_u32 << 16 : 0_u32) | (count.to_u32 << 24)
        end
      end
    end
  end

  # gb18030 and GBK (they share the decoder).
  class GB18030Decoder < Decoder
    include LegacyByteLoop

    @first = 0
    @second = 0
    @third = 0

    private def idle? : Bool
      @first == 0
    end

    # Two-byte characters only; four-byte sequences go through `step`.
    # Every pointer is below 126 * 190, the size of the index.
    @[AlwaysInline]
    private def pair_utf8(index : Slice(UInt32), leading : Int32, trailing : Int32) : UInt32
      valid = between?(leading, 0x81, 0xFE) & between?(trailing, 0x40, 0xFE) & (trailing != 0x7F)
      entry(index, valid, (leading &- 0x81) &* 190 &+ trailing &- (trailing < 0x7F ? 0x40 : 0x41))
    end

    @[AlwaysInline]
    private def utf8_index : Slice(UInt32)
      LegacyUTF8Index.gb18030
    end

    private def clear_state : Nil
      @first = 0
      @second = 0
      @third = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @first == 0 && @second == 0 && @third == 0
        clear_state
        return ERROR
      end
      if @third != 0
        if byte < 0x30 || byte > 0x39
          restore(@second, @third, byte)
          clear_state
          return ERROR
        end
        pointer = ((@first - 0x81) * (10 * 126 * 10)) + ((@second - 0x30) * (10 * 126)) + ((@third - 0x81) * 10) + byte - 0x30
        clear_state
        code_point = Tables.gb18030_ranges_code_point(pointer)
        return code_point < 0 ? ERROR : code_point
      end
      if @second != 0
        if byte >= 0x81 && byte <= 0xFE
          @third = byte
          return CONTINUE
        end
        restore(@second, byte)
        @first = 0
        @second = 0
        return ERROR
      end
      if @first != 0
        if byte >= 0x30 && byte <= 0x39
          @second = byte
          return CONTINUE
        end
        leading = @first
        @first = 0
        offset = byte < 0x7F ? 0x40 : 0x41
        code_point = -1
        if (byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFE)
          code_point = Tables.code_point(Tables::GB18030, (leading - 0x81) * 190 + (byte - offset))
        end
        return code_point if code_point >= 0
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      return 0x20AC if byte == 0x80
      if byte >= 0x81 && byte <= 0xFE
        @first = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # Big5 (the Encoding Standard's, which includes HKSCS); also the
  # decoder for BIG5-HKSCS.
  class Big5Decoder < Decoder
    include LegacyByteLoop

    @leading = 0

    private def idle? : Bool
      @leading == 0
    end

    # The four pointers that decode to two code points (1133, 1135, 1164,
    # 1166) are empty in the index, so they go through `step`. Every
    # pointer is below 126 * 157, the size of the index.
    @[AlwaysInline]
    private def pair_utf8(index : Slice(UInt32), leading : Int32, trailing : Int32) : UInt32
      valid = between?(leading, 0x81, 0xFE) & (between?(trailing, 0x40, 0x7E) | between?(trailing, 0xA1, 0xFE))
      entry(index, valid, (leading &- 0x81) &* 157 &+ trailing &- (trailing < 0x7F ? 0x40 : 0x62))
    end

    @[AlwaysInline]
    private def utf8_index : Slice(UInt32)
      LegacyUTF8Index.big5
    end

    private def clear_state : Nil
      @leading = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        @leading = 0
        return ERROR
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        offset = byte < 0x7F ? 0x40 : 0x62
        if (byte >= 0x40 && byte <= 0x7E) || (byte >= 0xA1 && byte <= 0xFE)
          pointer = (leading - 0x81) * 157 + (byte - offset)
          case pointer
          when 1133
            @extra_code_point = 0x0304
            return 0x00CA
          when 1135
            @extra_code_point = 0x030C
            return 0x00CA
          when 1164
            @extra_code_point = 0x0304
            return 0x00EA
          when 1166
            @extra_code_point = 0x030C
            return 0x00EA
          end
          code_point = Tables.code_point(Tables::BIG5, pointer)
          return code_point if code_point >= 0
        end
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      if byte >= 0x81 && byte <= 0xFE
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # EUC-JP (JIS X 0208, JIS X 0212 and halfwidth katakana).
  class EUCJPDecoder < Decoder
    include LegacyByteLoop

    @leading = 0
    @jis0212 = false

    private def idle? : Bool
      @leading == 0
    end

    # JIS X 0208 only; 0x8E (halfwidth katakana) and 0x8F (JIS X 0212)
    # go through `step`. Every pointer is below 94 * 94, inside the index.
    @[AlwaysInline]
    private def pair_utf8(index : Slice(UInt32), leading : Int32, trailing : Int32) : UInt32
      valid = between?(leading, 0xA1, 0xFE) & between?(trailing, 0xA1, 0xFE)
      entry(index, valid, (leading &- 0xA1) &* 94 &+ trailing &- 0xA1)
    end

    @[AlwaysInline]
    private def utf8_index : Slice(UInt32)
      LegacyUTF8Index.jis0208
    end

    private def clear_state : Nil
      @leading = 0
      @jis0212 = false
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        # Also forgets a JIS X 0212 lead (0x8F), so a decoder used again
        # after the end of its input starts clean.
        clear_state
        return ERROR
      end
      if @leading == 0x8E && byte >= 0xA1 && byte <= 0xDF
        @leading = 0
        return 0xFF61 - 0xA1 + byte
      end
      if @leading == 0x8F && byte >= 0xA1 && byte <= 0xFE
        @jis0212 = true
        @leading = byte
        return CONTINUE
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        code_point = -1
        if leading >= 0xA1 && leading <= 0xFE && byte >= 0xA1 && byte <= 0xFE
          pointer = (leading - 0xA1) * 94 + byte - 0xA1
          code_point = Tables.code_point(@jis0212 ? Tables::JIS0212 : Tables::JIS0208, pointer)
        end
        @jis0212 = false
        return code_point if code_point >= 0
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      if byte == 0x8E || byte == 0x8F || (byte >= 0xA1 && byte <= 0xFE)
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # ISO-2022-JP: ASCII, JIS X 0201 Roman, halfwidth katakana and JIS X 0208,
  # switched by escape sequences.
  class ISO2022JPDecoder < Decoder
    include LegacyByteLoop

    enum State
      ASCII
      Roman
      Katakana
      LeadByte
      TrailByte
      EscapeStart
      Escape
    end

    @state = State::ASCII
    @output_state = State::ASCII
    @leading = 0
    @output = false

    private def idle? : Bool
      @state.ascii? || @state.roman? || @state.katakana? || @state.lead_byte?
    end

    private def fast_path? : Bool
      false
    end

    private def ascii_passthrough? : Bool
      false
    end

    private def clear_state : Nil
      @state = State::ASCII
      @output_state = State::ASCII
      @leading = 0
      @output = false
    end

    private def step(byte : Int32) : Int32
      case @state
      in .ascii?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        return byte if byte <= 0x7F && byte != 0x0E && byte != 0x0F
        ERROR
      in .roman?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        return 0x00A5 if byte == 0x5C
        return 0x203E if byte == 0x7E
        return byte if byte <= 0x7F && byte != 0x0E && byte != 0x0F
        ERROR
      in .katakana?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        return 0xFF61 - 0x21 + byte if byte >= 0x21 && byte <= 0x5F
        ERROR
      in .lead_byte?
        return escape_start if byte == 0x1B
        return FINISHED if byte == END_OF_QUEUE
        @output = false
        if byte >= 0x21 && byte <= 0x7E
          @leading = byte
          @state = State::TrailByte
          return CONTINUE
        end
        ERROR
      in .trail_byte?
        if byte == 0x1B
          @state = State::EscapeStart
          return ERROR
        end
        @state = State::LeadByte
        if byte >= 0x21 && byte <= 0x7E
          code_point = Tables.code_point(Tables::JIS0208, (@leading - 0x21) * 94 + byte - 0x21)
          return code_point < 0 ? ERROR : code_point
        end
        ERROR
      in .escape_start?
        if byte == 0x24 || byte == 0x28
          @leading = byte
          @state = State::Escape
          return CONTINUE
        end
        restore(byte) unless byte == END_OF_QUEUE
        @output = false
        @state = @output_state
        ERROR
      in .escape?
        leading = @leading
        @leading = 0
        state = if leading == 0x28 && byte == 0x42
                  State::ASCII
                elsif leading == 0x28 && byte == 0x4A
                  State::Roman
                elsif leading == 0x28 && byte == 0x49
                  State::Katakana
                elsif leading == 0x24 && (byte == 0x40 || byte == 0x42)
                  State::LeadByte
                end
        if state
          @state = state
          @output_state = state
          output = @output
          @output = true
          return output ? ERROR : CONTINUE
        end
        if byte == END_OF_QUEUE
          restore(leading)
        else
          restore(leading, byte)
        end
        @output = false
        @state = @output_state
        ERROR
      end
    end

    private def escape_start : Int32
      @state = State::EscapeStart
      CONTINUE
    end
  end

  # Shift_JIS (with the Windows extensions the Encoding Standard keeps).
  class ShiftJISDecoder < Decoder
    include LegacyByteLoop

    @leading = 0

    private def idle? : Bool
      @leading == 0
    end

    # Two-byte characters only; single bytes (0x80, halfwidth katakana) go
    # through `step`.
    @[AlwaysInline]
    private def pair_utf8(index : Slice(UInt32), leading : Int32, trailing : Int32) : UInt32
      valid = (between?(leading, 0x81, 0x9F) | between?(leading, 0xE0, 0xFC)) & between?(trailing, 0x40, 0xFC) & (trailing != 0x7F)
      entry(index, valid, (leading &- (leading < 0xA0 ? 0x81 : 0xC1)) &* 188 &+ trailing &- (trailing < 0x7F ? 0x40 : 0x41))
    end

    @[AlwaysInline]
    private def utf8_index : Slice(UInt32)
      LegacyUTF8Index.jis0208
    end

    private def clear_state : Nil
      @leading = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        @leading = 0
        return ERROR
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        offset = byte < 0x7F ? 0x40 : 0x41
        leading_offset = leading < 0xA0 ? 0x81 : 0xC1
        if (byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFC)
          pointer = (leading - leading_offset) * 188 + byte - offset
          return 0xE000 - 8836 + pointer if pointer >= 8836 && pointer <= 10715
          code_point = Tables.code_point(Tables::JIS0208, pointer)
          return code_point if code_point >= 0
        end
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80 || byte == 0x80
      return 0xFF61 - 0xA1 + byte if byte >= 0xA1 && byte <= 0xDF
      if (byte >= 0x81 && byte <= 0x9F) || (byte >= 0xE0 && byte <= 0xFC)
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # EUC-KR (the Unified Hangul Code, Windows code page 949).
  class EUCKRDecoder < Decoder
    include LegacyByteLoop

    @leading = 0

    private def idle? : Bool
      @leading == 0
    end

    @[AlwaysInline]
    private def pair_utf8(index : Slice(UInt32), leading : Int32, trailing : Int32) : UInt32
      valid = between?(leading, 0x81, 0xFE) & between?(trailing, 0x41, 0xFE)
      entry(index, valid, (leading &- 0x81) &* 190 &+ trailing &- 0x41)
    end

    @[AlwaysInline]
    private def utf8_index : Slice(UInt32)
      LegacyUTF8Index.euc_kr
    end

    private def clear_state : Nil
      @leading = 0
    end

    private def step(byte : Int32) : Int32
      if byte == END_OF_QUEUE
        return FINISHED if @leading == 0
        @leading = 0
        return ERROR
      end
      if @leading != 0
        leading = @leading
        @leading = 0
        if byte >= 0x41 && byte <= 0xFE
          code_point = Tables.code_point(Tables::EUC_KR, (leading - 0x81) * 190 + (byte - 0x41))
          return code_point if code_point >= 0
        end
        restore(byte) if byte < 0x80
        return ERROR
      end
      return byte if byte < 0x80
      if byte >= 0x81 && byte <= 0xFE
        @leading = byte
        return CONTINUE
      end
      ERROR
    end
  end

  # The replacement encoding: any input at all becomes one error.
  class ReplacementDecoder < Decoder
    include LegacyByteLoop

    @error_returned = false

    private def idle? : Bool
      true
    end

    private def fast_path? : Bool
      false
    end

    private def ascii_passthrough? : Bool
      false
    end

    private def clear_state : Nil
      @error_returned = false
    end

    private def step(byte : Int32) : Int32
      return FINISHED if byte == END_OF_QUEUE
      return CONTINUE if @error_returned
      @error_returned = true
      ERROR
    end
  end
end
