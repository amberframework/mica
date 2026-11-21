module Mica::Deflate
  # The container around a DEFLATE stream.
  enum Format
    # Raw DEFLATE (RFC 1951).
    Raw
    # zlib (RFC 1950): a two-byte header, DEFLATE data and an Adler-32.
    Zlib
    # gzip (RFC 1952): one or more members, each a header, DEFLATE data, a
    # CRC-32 and the size modulo 2^32.
    Gzip
  end

  # The decoding engine behind `Mica::Deflate`, `Mica::Zlib` and
  # `Mica::Gzip`, one-shot and streaming.
  #
  # Input is pulled: when the decoder needs bits it reads them from its
  # source (a `Bytes` in place, or an `IO` through a 64 KiB buffer), so the
  # only place it stops is a full output buffer, between symbols or inside
  # a back reference or stored block. Output goes into one buffer that
  # also holds the history back references read:
  #
  # - one-shot: the buffer is the result. It grows by doubling as bytes are
  #   produced, never past `max_output_bytes`;
  # - streaming: the buffer holds the 32 KiB window plus up to 128 KiB of
  #   new output; once the reader has taken the new output, the last 32 KiB
  #   slide to the front.
  #
  # Every run of the decoding loop produces at most `RUN_BYTES` before the
  # decoder settles the work meter, the ratio check and the deadline, and
  # the output limit is checked byte-exactly: when the next byte would pass
  # `max_output_bytes` the decode raises `DecodeLimitError` and the byte is
  # never written.
  #
  # Decoding uses a 64-bit bit buffer refilled eight bytes at a time and
  # two-level Huffman tables (`HuffmanTable`), with a fast loop for the
  # stretch where at least 8 input bytes and 258 bytes of output room
  # remain, and a careful loop for the edges.
  #
  # WARNING: An inflater belongs to one fiber at a time.
  #
  # :nodoc:
  class Inflater
    # The DEFLATE window.
    WINDOW = 32_768
    # The longest back reference.
    MAX_MATCH = 258
    # The most output one run of the decoding loop produces before the
    # work meter, the ratio check and the deadline are settled.
    RUN_BYTES = 65_536
    # Bytes allocated past an output buffer's logical end, so the fast
    # loop's 8-byte copies may run over the end of a back reference.
    SLACK = 16
    # The streaming output buffer: the window plus two runs.
    STREAM_BUFFER = WINDOW + 2 * RUN_BYTES
    # The streaming input buffer.
    INPUT_BUFFER = 65_536
    # Bytes kept before the read position when the input buffer is
    # compacted, so the decoder can hand back up to 7 bytes it loaded into
    # its bit buffer but did not use.
    INPUT_LOOKBACK = 8
    # The streaming decoder refills its input before the fast loop when
    # fewer bytes than this remain.
    INPUT_LOW_WATER = 4_096

    # Order of the code length code lengths (RFC 1951, section 3.2.7).
    CODE_LENGTH_ORDER = StaticArray[16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    # For a back reference closer than 8 bytes: the smallest multiple of
    # its distance that is at least 8.
    PATTERN_PERIODS = StaticArray[0, 8, 8, 9, 8, 10, 12, 14]

    LITERAL_LENGTH_MASK = 0x3FF_u64
    DISTANCE_MASK       =  0xFF_u64
    CODE_LENGTH_MASK    =  0x7F_u64

    private enum Phase
      StreamHeader
      BlockHeader
      Stored
      Huffman
      Trailer
      Done
    end

    # The gzip member headers read so far (empty for other formats).
    getter list_of_headers = [] of Gzip::Header

    # Decoded bytes so far, across every member.
    getter produced : Int64 = 0_i64

    @format : Format
    @limits : DecodeLimits
    @meter : Core::WorkMeter
    @dictionary : Bytes?
    @one_shot : Bool

    # Input.
    @io : IO?
    @input : UInt8*
    @input_buffer : Bytes?
    @in_pos : Int32 = 0
    @in_end : Int32 = 0
    @in_base : Int64 = 0_i64
    @io_done : Bool = false
    @bit_buffer : UInt64 = 0_u64
    @bit_count : Int32 = 0

    # Output.
    @out : UInt8*
    @out_capacity : Int32
    @out_pos : Int32 = 0
    @out_start : Int32 = 0
    @out_checked : Int32 = 0
    @result_start : Int32 = 0
    @lowest_reference : Int32 = 0
    @window_limit : Int32

    # Decoding state.
    @phase : Phase = Phase::StreamHeader
    @final_block : Bool = false
    @stored_left : Int32 = 0
    @copy_left : Int32 = 0
    @copy_distance : Int32 = 0
    @literal_length_table : UInt32*
    @distance_table : UInt32*
    @dynamic_literal_length : Slice(UInt32)
    @dynamic_distance : Slice(UInt32)
    @code_length_table : Slice(UInt32)
    @lengths : Slice(UInt8)

    # Checks.
    @members : Int32 = 0
    @checksum : UInt32 = 0_u32
    @member_size : UInt32 = 0_u32
    @metered_input : Int64 = 0_i64
    @metered_output : Int64 = 0_i64

    def initialize(source : Bytes | IO, @format : Format, @limits : DecodeLimits, timeout : Time::Span?,
                   @dictionary : Bytes? = nil)
      @meter = Core::WorkMeter.new(@limits.work_budget(timeout))
      @window_limit = @limits.max_window_bytes
      if source.is_a?(Bytes)
        @one_shot = true
        @input = source.to_unsafe
        @in_end = source.size
        @io_done = true
        initial = source.size.to_i64 * 4 + RUN_BYTES
        initial = @limits.max_output_bytes + WINDOW if initial > @limits.max_output_bytes + WINDOW
        @out_capacity = initial.to_i32
      else
        @one_shot = false
        @io = source
        buffer = Bytes.new(INPUT_BUFFER)
        @input_buffer = buffer
        @input = buffer.to_unsafe
        @out_capacity = STREAM_BUFFER
      end
      @out = GC.malloc_atomic((@out_capacity + SLACK).to_u64).as(UInt8*)
      @dynamic_literal_length = Slice(UInt32).new(HuffmanTable::LITERAL_LENGTH_ENTRIES, HuffmanTable::INVALID)
      @dynamic_distance = Slice(UInt32).new(HuffmanTable::DISTANCE_ENTRIES, HuffmanTable::INVALID)
      @code_length_table = Slice(UInt32).new(HuffmanTable::CODE_LENGTH_ENTRIES, HuffmanTable::INVALID)
      @lengths = Slice(UInt8).new(320, 0_u8)
      @literal_length_table = @dynamic_literal_length.to_unsafe
      @distance_table = @dynamic_distance.to_unsafe
      @meter.enforce_deadline("while decoding") { position }
    end

    # Decodes the whole stream and returns its output (one-shot only).
    def decode_all : Bytes
      while produce
      end
      size = @out_pos - @result_start
      return Bytes.empty if size == 0
      Bytes.new(@out + @result_start, size)
    end

    # Returns the decoded bytes the caller has not taken yet (streaming).
    def pending : Bytes
      Bytes.new(@out + @out_start, @out_pos - @out_start)
    end

    # Marks *count* pending bytes as taken.
    def take(count : Int32) : Nil
      @out_start += count
    end

    # Returns true when the stream ended and every check passed.
    def done? : Bool
      @phase.done?
    end

    # Decodes until new output is pending or the stream ends. Returns false
    # once the stream has ended (and its trailers have been checked).
    def produce : Bool
      before = @produced
      loop do
        case @phase
        in .stream_header?
          read_stream_header
        in .block_header?
          read_block_header
        in .stored?, .huffman?
          limit, capped = prepare_output
          if @phase.stored?
            copy_stored(limit, capped)
          else
            decode_huffman(limit, capped)
          end
          settle
          return true if @produced > before
        in .trailer?
          read_trailer
        in .done?
          return @produced > before
        end
      end
    end

    # The byte of the source the decoder has reached.
    private def input_offset : Int64
      @in_base + @in_pos - (@bit_count >> 3)
    end

    private def position : Core::Position
      Core::Position.new(input_offset)
    end

    private def malformed(message : String) : NoReturn
      raise MalformedStreamError.new(message, position)
    end

    private def truncated(where : String) : NoReturn
      raise TruncatedStreamError.new("Input ends inside #{where}", position)
    end

    private def limit_exceeded(limit : String, message : String) : NoReturn
      raise DecodeLimitError.new(message, position, limit)
    end

    # ---- input ----

    # Reads more input into the buffer (streaming). Returns false at the
    # end of the source.
    private def refill_input : Bool
      io = @io
      buffer = @input_buffer
      return false if @io_done || io.nil? || buffer.nil?
      keep_from = @in_pos - INPUT_LOOKBACK
      keep_from = 0 if keep_from < 0
      if keep_from > 0
        kept = @in_end - keep_from
        buffer.to_unsafe.move_from(buffer.to_unsafe + keep_from, kept)
        @in_base += keep_from
        @in_pos -= keep_from
        @in_end = kept
      end
      count = io.read(buffer[@in_end, buffer.size - @in_end])
      @meter.enforce_deadline("while decoding") { position }
      if count == 0
        @io_done = true
        return false
      end
      @in_end += count
      true
    end

    # Makes sure the bit buffer holds at least *count* bits (at most 56).
    # Returns false when the source ends first.
    private def need_bits(count : Int32) : Bool
      while @bit_count < count
        if @in_pos == @in_end
          return false unless refill_input
        end
        @bit_buffer |= @input[@in_pos].to_u64.unsafe_shl(@bit_count)
        @in_pos += 1
        @bit_count += 8
      end
      true
    end

    # Takes *count* bits (at most 32), raising `TruncatedStreamError` with
    # *where* when the source ends first.
    private def take_bits(count : Int32, where : String) : UInt32
      truncated(where) unless need_bits(count)
      value = (@bit_buffer & (1_u64.unsafe_shl(count) &- 1)).to_u32!
      @bit_buffer = @bit_buffer.unsafe_shr(count)
      @bit_count -= count
      value
    end

    # Drops the bits up to the next byte boundary and hands the whole bytes
    # still in the bit buffer back to the input.
    private def align_to_byte : Nil
      drop = @bit_count & 7
      @bit_buffer = @bit_buffer.unsafe_shr(drop)
      @bit_count -= drop
      @in_pos -= @bit_count >> 3
      @bit_buffer = 0_u64
      @bit_count = 0
    end

    # Reads one byte (the bit buffer must be empty).
    private def read_byte(where : String) : UInt8
      if @in_pos == @in_end
        truncated(where) unless refill_input
      end
      byte = @input[@in_pos]
      @in_pos += 1
      byte
    end

    private def read_u16_le(where : String) : UInt32
      read_byte(where).to_u32 | (read_byte(where).to_u32 << 8)
    end

    private def read_u32_le(where : String) : UInt32
      read_u16_le(where) | (read_u16_le(where) << 16)
    end

    # Returns true when no input byte remains (the bit buffer must be
    # empty).
    private def at_input_end? : Bool
      return false if @in_pos < @in_end
      !refill_input
    end

    # ---- output ----

    # Makes room for the next run and returns the index it may write up to
    # and whether that index is `max_output_bytes` (so that writing past it
    # must raise rather than wait for room).
    private def prepare_output : {Int32, Bool}
      if @one_shot
        grow_output if @out_capacity - @out_pos < RUN_BYTES
      elsif @out_pos > WINDOW + RUN_BYTES
        slide_window
      end
      space = @out_capacity - @out_pos
      space = RUN_BYTES if space > RUN_BYTES
      allowed = @limits.max_output_bytes - @produced
      if allowed <= space
        {@out_pos + allowed.to_i32, true}
      else
        {@out_pos + space, false}
      end
    end

    private def grow_output : Nil
      ceiling = @limits.max_output_bytes + @result_start
      wanted = @out_capacity.to_i64 * 2
      wanted = @out_pos.to_i64 + RUN_BYTES if wanted < @out_pos.to_i64 + RUN_BYTES
      wanted = ceiling if wanted > ceiling
      wanted = Int32::MAX.to_i64 - SLACK if wanted > Int32::MAX - SLACK
      return if wanted <= @out_capacity
      @out = GC.realloc(@out.as(Void*), (wanted + SLACK).to_u64).as(UInt8*)
      @out_capacity = wanted.to_i32
    end

    # Moves the last 32 KiB of output to the front of the streaming buffer
    # (the reader has taken everything before `@out_pos`).
    private def slide_window : Nil
      shift = @out_pos - WINDOW
      @out.move_from(@out + shift, WINDOW)
      @out_pos -= shift
      @out_start -= shift
      @out_checked -= shift
      @lowest_reference = Math.max(@lowest_reference - shift, 0)
    end

    # Settles a run: updates the member checksum and size over the new
    # output, then the work meter, the ratio check and the deadline.
    private def settle : Nil
      new_bytes = @out_pos - @out_checked
      if new_bytes > 0
        start = @out + @out_checked
        case @format
        in .zlib? then @checksum = Adler32.update(@checksum, start, new_bytes)
        in .gzip? then @checksum = CRC32.update(@checksum, start, new_bytes)
        in .raw?
        end
        @member_size &+= new_bytes.to_u32!
        @produced += new_bytes
        @out_checked = @out_pos
      end
      meter_progress
    end

    private def meter_progress : Nil
      consumed = input_offset
      delta = (consumed - @metered_input) + (@produced - @metered_output)
      @metered_input = consumed
      @metered_output = @produced
      if delta > 0
        @meter.add_units(delta)
        @meter.enforce("while decoding") { position } if @meter.charge(delta)
      end
      if @produced > DecodeLimits::RATIO_GRACE_BYTES && @produced > @limits.max_ratio &* Math.max(consumed, 1_i64)
        limit_exceeded("max_ratio", "Output grew past max_ratio (#{@limits.max_ratio}:1): #{@produced} bytes from #{consumed}")
      end
    end

    private def charge_work(count : Int32) : Nil
      @meter.enforce("while decoding") { position } if @meter.charge(count)
    end

    # ---- containers ----

    private def read_stream_header : Nil
      case @format
      in .raw?
        start_member
      in .zlib?
        read_zlib_header
      in .gzip?
        read_gzip_header
      end
      @phase = Phase::BlockHeader
    end

    private def start_member : Nil
      @members += 1
      if @members > @limits.max_members
        limit_exceeded("max_members", "More than max_members (#{@limits.max_members}) members")
      end
      @lowest_reference = @out_pos
      @final_block = false
      @member_size = 0_u32
      @checksum = @format.zlib? ? 1_u32 : 0_u32
    end

    private def read_zlib_header : Nil
      start_member
      cmf = read_byte("the zlib header")
      flg = read_byte("the zlib header")
      malformed("Incorrect zlib header check") unless (cmf.to_u32 * 256 + flg) % 31 == 0
      malformed("Unknown compression method #{cmf & 0x0F} in the zlib header") unless cmf & 0x0F == 8
      window_bits = (cmf >> 4).to_i32 + 8
      malformed("Invalid window size in the zlib header (CINFO #{cmf >> 4})") if window_bits > 15
      if (1 << window_bits) > @limits.max_window_bytes
        limit_exceeded("max_window_bytes", "The zlib header declares a #{1 << window_bits}-byte window, over max_window_bytes (#{@limits.max_window_bytes})")
      end
      return unless flg & 0x20 != 0
      expected = (read_byte("the dictionary id").to_u32 << 24) | (read_byte("the dictionary id").to_u32 << 16) |
                 (read_byte("the dictionary id").to_u32 << 8) | read_byte("the dictionary id").to_u32
      dictionary = @dictionary
      malformed("The stream needs a preset dictionary") unless dictionary
      unless Adler32.update(1_u32, dictionary) == expected
        raise ChecksumError.new("The preset dictionary does not match the stream's dictionary id", position)
      end
      load_dictionary(dictionary)
    end

    # Places the last 32 KiB of *dictionary* in the history before the
    # output (it is history only: not output, not checksummed).
    private def load_dictionary(dictionary : Bytes) : Nil
      used = dictionary.size > WINDOW ? dictionary[dictionary.size - WINDOW, WINDOW] : dictionary
      charge_work(used.size)
      (@out + @out_pos).copy_from(used.to_unsafe, used.size)
      @lowest_reference = @out_pos
      @out_pos += used.size
      @out_start = @out_pos
      @out_checked = @out_pos
      @result_start = @out_pos if @one_shot
    end

    private def read_gzip_header : Nil
      start_member
      header = Bytes.new(10)
      header.size.times { |index| header[index] = read_byte("the gzip header") }
      malformed("Not a gzip member (bad magic bytes)") unless header[0] == 0x1F && header[1] == 0x8B
      malformed("Unknown compression method #{header[2]} in the gzip header") unless header[2] == 8
      flags = header[3]
      malformed("Reserved gzip header flags are set") unless flags & 0xE0 == 0
      header_crc = CRC32.update(0_u32, header)
      metadata = 0
      extra_field = nil
      if flags & 0x04 != 0
        length_bytes = Bytes[read_byte("FEXTRA"), read_byte("FEXTRA")]
        header_crc = CRC32.update(header_crc, length_bytes)
        length = length_bytes[0].to_i32 | (length_bytes[1].to_i32 << 8)
        metadata = add_metadata(metadata, length)
        extra = Bytes.new(length)
        length.times { |index| extra[index] = read_byte("FEXTRA") }
        header_crc = CRC32.update(header_crc, extra)
        extra_field = extra
      end
      file_name = nil
      if flags & 0x08 != 0
        file_name, metadata, header_crc = read_zero_terminated("FNAME", metadata, header_crc)
      end
      comment = nil
      if flags & 0x10 != 0
        comment, metadata, header_crc = read_zero_terminated("FCOMMENT", metadata, header_crc)
      end
      if flags & 0x02 != 0
        stored = read_u16_le("FHCRC")
        unless stored == header_crc & 0xFFFF
          raise ChecksumError.new("The gzip header CRC (FHCRC) does not match", position)
        end
      end
      @list_of_headers << Gzip::Header.new(
        modification_time: header[4].to_u32 | (header[5].to_u32 << 8) | (header[6].to_u32 << 16) | (header[7].to_u32 << 24),
        extra_flags: header[8], operating_system: header[9], is_text: flags & 0x01 != 0,
        extra_field: extra_field, file_name: file_name, comment: comment)
    end

    private def add_metadata(metadata : Int32, count : Int32) : Int32
      total = metadata + count
      if total > @limits.max_metadata_bytes
        limit_exceeded("max_metadata_bytes", "gzip header fields pass max_metadata_bytes (#{@limits.max_metadata_bytes})")
      end
      charge_work(count)
      total
    end

    private def read_zero_terminated(field : String, metadata : Int32, header_crc : UInt32) : {Bytes, Int32, UInt32}
      bytes = IO::Memory.new
      loop do
        byte = read_byte(field)
        header_crc = CRC32.update(header_crc, Bytes[byte])
        break if byte == 0
        metadata = add_metadata(metadata, 1)
        bytes.write_byte(byte)
      end
      {bytes.to_slice, metadata, header_crc}
    end

    private def read_trailer : Nil
      align_to_byte
      case @format
      in .raw?
        nil
      in .zlib?
        stored = read_u32_le("the Adler-32 trailer").byte_swap
        raise ChecksumError.new("Adler-32 mismatch", position) unless stored == @checksum
      in .gzip?
        stored_crc = read_u32_le("the CRC-32 trailer")
        raise ChecksumError.new("CRC-32 mismatch", position) unless stored_crc == @checksum
        stored_size = read_u32_le("the ISIZE trailer")
        raise ChecksumError.new("ISIZE mismatch", position) unless stored_size == @member_size
        unless at_input_end?
          @phase = Phase::StreamHeader
          return
        end
      end
      malformed("Trailing data after the end of the stream") unless at_input_end?
      @phase = Phase::Done
    end

    # ---- blocks ----

    private def read_block_header : Nil
      if @final_block
        @phase = Phase::Trailer
        return
      end
      meter_progress
      charge_work(1)
      header = take_bits(3, "a block header")
      @final_block = header & 1 == 1
      case header >> 1
      when 0
        align_to_byte
        length = read_u16_le("a stored block header")
        complement = read_u16_le("a stored block header")
        malformed("Stored block length does not match its complement") unless length == (~complement & 0xFFFF)
        @stored_left = length.to_i32
        @phase = Phase::Stored
      when 1
        @literal_length_table = HuffmanTable::FIXED_LITERAL_LENGTH.to_unsafe
        @distance_table = HuffmanTable::FIXED_DISTANCE.to_unsafe
        @phase = Phase::Huffman
      when 2
        read_dynamic_tables
        @literal_length_table = @dynamic_literal_length.to_unsafe
        @distance_table = @dynamic_distance.to_unsafe
        @phase = Phase::Huffman
      else
        malformed("Invalid block type 3")
      end
    end

    private def read_dynamic_tables : Nil
      literal_count = take_bits(5, "a dynamic block header").to_i32 + 257
      distance_count = take_bits(5, "a dynamic block header").to_i32 + 1
      code_length_count = take_bits(4, "a dynamic block header").to_i32 + 4
      if literal_count > 286 || distance_count > 30
        malformed("Too many length or distance symbols (HLIT #{literal_count}, HDIST #{distance_count})")
      end
      lengths = @lengths.to_unsafe
      19.times { |index| lengths[index] = 0_u8 }
      code_length_count.times do |index|
        lengths[CODE_LENGTH_ORDER[index]] = take_bits(3, "the code length code").to_u8
      end
      build_table(@code_length_table, lengths, 19, HuffmanTable::CODE_LENGTH_ROOT,
        HuffmanTable::Alphabet::CodeLength, "code length")

      total = literal_count + distance_count
      table = @code_length_table.to_unsafe
      index = 0
      while index < total
        entry = decode_careful(table, CODE_LENGTH_MASK, HuffmanTable::CODE_LENGTH_ROOT, "the code lengths")
        symbol = (entry >> 16).to_i32
        if symbol < 16
          lengths[index] = symbol.to_u8
          index += 1
          next
        end
        if symbol == 16
          malformed("Repeat code 16 with no previous length") if index == 0
          value = lengths[index - 1]
          repeat = 3 + take_bits(2, "the code lengths").to_i32
        elsif symbol == 17
          value = 0_u8
          repeat = 3 + take_bits(3, "the code lengths").to_i32
        else
          value = 0_u8
          repeat = 11 + take_bits(7, "the code lengths").to_i32
        end
        malformed("Code length repeat runs past the code lengths") if index + repeat > total
        repeat.times do
          lengths[index] = value
          index += 1
        end
      end
      malformed("The literal/length code has no end-of-block code") if lengths[256] == 0
      build_table(@dynamic_literal_length, lengths, literal_count, HuffmanTable::LITERAL_LENGTH_ROOT,
        HuffmanTable::Alphabet::LiteralLength, "literal/length")
      build_table(@dynamic_distance, lengths + literal_count, distance_count, HuffmanTable::DISTANCE_ROOT,
        HuffmanTable::Alphabet::Distance, "distance")
      charge_work(total)
    end

    private def build_table(table : Slice(UInt32), lengths : UInt8*, count : Int32, root : Int32,
                            alphabet : HuffmanTable::Alphabet, name : String) : Nil
      problem, written = HuffmanTable.build(table.to_unsafe, table.size, lengths, count, root, alphabet)
      case problem
      in .oversubscribed? then malformed("Oversubscribed #{name} code")
      in .incomplete?     then malformed("Incomplete #{name} code")
      in .none?
      end
      charge_work(written)
    end

    # Decodes one entry of *table* bit by bit with refills from the source.
    # Raises at an invalid code or when the source ends inside the code.
    # The returned entry's code bits are consumed (not its extra bits).
    private def decode_careful(table : UInt32*, mask : UInt64, root : Int32, where : String) : UInt32
      need_bits(15)
      entry = table[@bit_buffer & mask]
      if entry & HuffmanTable::SUBTABLE != 0
        truncated(where) if @bit_count < root
        @bit_buffer = @bit_buffer.unsafe_shr(root)
        @bit_count -= root
        sub_mask = (1_u64.unsafe_shl((entry >> 8) & 0xF)) &- 1
        entry = table[(entry >> 16) + (@bit_buffer & sub_mask)]
      end
      length = (entry & 0xFF).to_i32
      if entry & HuffmanTable::EXCEPTIONAL != 0 && entry & HuffmanTable::END_OF_BLOCK == 0
        truncated(where) if @io_done && @in_pos == @in_end && @bit_count < 15
        malformed("Invalid Huffman code in #{where}")
      end
      truncated(where) if length > @bit_count
      @bit_buffer = @bit_buffer.unsafe_shr(length)
      @bit_count -= length
      entry
    end

    # Copies stored-block bytes up to *limit*.
    private def copy_stored(limit : Int32, capped : Bool) : Nil
      while @stored_left > 0
        if @out_pos == limit
          output_limit_reached if capped
          return
        end
        if @in_pos == @in_end
          truncated("a stored block") unless refill_input
        end
        count = Math.min(@stored_left, Math.min(@in_end - @in_pos, limit - @out_pos))
        (@out + @out_pos).copy_from(@input + @in_pos, count)
        @out_pos += count
        @in_pos += count
        @stored_left -= count
      end
      @phase = Phase::BlockHeader
    end

    private def output_limit_reached : NoReturn
      limit_exceeded("max_output_bytes", "Output would pass max_output_bytes (#{@limits.max_output_bytes})")
    end

    # Decodes Huffman-coded symbols until the end of the block or *limit*.
    private def decode_huffman(limit : Int32, capped : Bool) : Nil
      loop do
        if @copy_left > 0
          return unless finish_copy(limit, capped)
        end
        if !@one_shot && @in_end - @in_pos < INPUT_LOW_WATER && !@io_done
          refill_input
        end
        if @in_end - @in_pos >= 8 && limit - @out_pos >= MAX_MATCH
          decode_fast(limit)
          return unless @phase.huffman?
        end
        return unless decode_one_careful(limit, capped)
        return unless @phase.huffman?
      end
    end

    # Finishes a back reference that the last run stopped inside. Returns
    # false when *limit* stopped it again.
    private def finish_copy(limit : Int32, capped : Bool) : Bool
      while @copy_left > 0
        if @out_pos == limit
          output_limit_reached if capped
          return false
        end
        @out[@out_pos] = @out[@out_pos - @copy_distance]
        @out_pos += 1
        @copy_left -= 1
      end
      true
    end

    # Decodes one symbol with full checks at every step. Returns false when
    # the run must stop (no room before *limit*).
    private def decode_one_careful(limit : Int32, capped : Bool) : Bool
      if @out_pos == limit && !capped
        return false
      end
      entry = decode_careful(@literal_length_table, LITERAL_LENGTH_MASK, HuffmanTable::LITERAL_LENGTH_ROOT,
        "a Huffman block")
      if entry & HuffmanTable::LITERAL != 0
        output_limit_reached if @out_pos == limit
        @out[@out_pos] = (entry >> 16).to_u8!
        @out_pos += 1
        return true
      end
      if entry & HuffmanTable::END_OF_BLOCK != 0
        @phase = Phase::BlockHeader
        return true
      end
      length = (entry >> 16).to_i32 + take_bits(((entry >> 8) & 0xF).to_i32, "a length").to_i32
      distance_entry = decode_careful(@distance_table, DISTANCE_MASK, HuffmanTable::DISTANCE_ROOT, "a distance")
      malformed("Invalid distance code") if distance_entry & HuffmanTable::EXCEPTIONAL != 0
      distance = (distance_entry >> 16).to_i32 + take_bits(((distance_entry >> 8) & 0xF).to_i32, "a distance").to_i32
      check_distance(distance)
      @copy_left = length
      @copy_distance = distance
      finish_copy(limit, capped)
    end

    private def check_distance(distance : Int32) : Nil
      if distance > @out_pos - @lowest_reference
        malformed("Invalid distance too far back (#{distance})")
      end
      if distance > @window_limit
        limit_exceeded("max_window_bytes", "Back reference of #{distance} bytes passes max_window_bytes (#{@window_limit})")
      end
    end

    @[AlwaysInline]
    private def load_u64(pointer : UInt8*) : UInt64
      value = uninitialized UInt64
      pointerof(value).as(UInt8*).copy_from(pointer, 8)
      {% if IO::ByteFormat::SystemEndian != IO::ByteFormat::LittleEndian %}
        value = value.byte_swap
      {% end %}
      value
    end

    # The fast loop: runs while at least 8 input bytes and 258 bytes of
    # output room remain, so it refills the bit buffer with one 8-byte
    # load per symbol and copies back references 8 bytes at a time
    # without bounds checks. Leaves through the end of the block or its
    # bounds; the careful loop takes over at the edges.
    private def decode_fast(limit : Int32) : Nil
      input = @input
      in_pos = @in_pos
      in_stop = @in_end - 8
      out = @out
      out_pos = @out_pos
      out_stop = limit - MAX_MATCH
      bit_buffer = @bit_buffer
      bit_count = @bit_count.to_u32
      literal_lengths = @literal_length_table
      distances = @distance_table
      lowest = @lowest_reference
      window = @window_limit
      problem = 0

      while in_pos <= in_stop && out_pos <= out_stop
        bit_buffer |= load_u64(input + in_pos).unsafe_shl(bit_count)
        in_pos &+= ((63_u32 &- bit_count) >> 3).to_i32!
        bit_count |= 56_u32

        entry = literal_lengths[(bit_buffer & LITERAL_LENGTH_MASK).to_i32!]
        if entry & HuffmanTable::SUBTABLE != 0
          bit_buffer = bit_buffer.unsafe_shr(HuffmanTable::LITERAL_LENGTH_ROOT)
          bit_count &-= HuffmanTable::LITERAL_LENGTH_ROOT
          entry = literal_lengths[((entry >> 16) &+ (bit_buffer & (1_u64.unsafe_shl((entry >> 8) & 0xF) &- 1))).to_i32!]
        end
        code_bits = entry & 0xFF
        bit_buffer = bit_buffer.unsafe_shr(code_bits)
        bit_count &-= code_bits

        if entry & HuffmanTable::LITERAL != 0
          out[out_pos] = (entry >> 16).to_u8!
          out_pos &+= 1
          # A second literal from the same refill (at least 41 bits remain).
          entry = literal_lengths[(bit_buffer & LITERAL_LENGTH_MASK).to_i32!]
          if entry & HuffmanTable::LITERAL != 0
            code_bits = entry & 0xFF
            bit_buffer = bit_buffer.unsafe_shr(code_bits)
            bit_count &-= code_bits
            out[out_pos] = (entry >> 16).to_u8!
            out_pos &+= 1
          end
          next
        end

        if entry & HuffmanTable::EXCEPTIONAL != 0
          if entry & HuffmanTable::END_OF_BLOCK != 0
            @phase = Phase::BlockHeader
          else
            problem = 1
          end
          break
        end

        extra = (entry >> 8) & 0xF
        length = ((entry >> 16) &+ (bit_buffer & (1_u64.unsafe_shl(extra) &- 1))).to_i32!
        bit_buffer = bit_buffer.unsafe_shr(extra)
        bit_count &-= extra

        entry = distances[(bit_buffer & DISTANCE_MASK).to_i32!]
        if entry & HuffmanTable::SUBTABLE != 0
          bit_buffer = bit_buffer.unsafe_shr(HuffmanTable::DISTANCE_ROOT)
          bit_count &-= HuffmanTable::DISTANCE_ROOT
          entry = distances[((entry >> 16) &+ (bit_buffer & (1_u64.unsafe_shl((entry >> 8) & 0xF) &- 1))).to_i32!]
        end
        if entry & HuffmanTable::EXCEPTIONAL != 0
          problem = 2
          break
        end
        code_bits = entry & 0xFF
        bit_buffer = bit_buffer.unsafe_shr(code_bits)
        bit_count &-= code_bits
        extra = (entry >> 8) & 0xF
        distance = ((entry >> 16) &+ (bit_buffer & (1_u64.unsafe_shl(extra) &- 1))).to_i32!
        bit_buffer = bit_buffer.unsafe_shr(extra)
        bit_count &-= extra

        if distance > out_pos &- lowest || distance > window
          problem = 3
          @copy_distance = distance
          break
        end

        destination = out + out_pos
        source = destination - distance
        if distance >= 16
          copied = 0
          while copied < length
            (destination + copied).copy_from(source + copied, 16)
            copied &+= 16
          end
        elsif distance >= 8
          copied = 0
          while copied < length
            (destination + copied).copy_from(source + copied, 8)
            copied &+= 8
          end
        else
          # Write the first repetitions of the pattern a byte at a time,
          # until a whole multiple of it (its period, at least 8 bytes)
          # sits behind the copy; then copy 8 bytes at a time from one
          # period back.
          period = PATTERN_PERIODS[distance]
          first = length < period ? length : period
          copied = 0
          while copied < first
            destination[copied] = source[copied]
            copied &+= 1
          end
          source = destination - period
          while copied < length
            (destination + copied).copy_from(source + copied, 8)
            copied &+= 8
          end
        end
        out_pos &+= length
      end

      @in_pos = in_pos
      @out_pos = out_pos
      @bit_count = bit_count.to_i32!
      # Clear the bits above the count that the 8-byte refill loaded
      # (they repeat the next input byte).
      @bit_buffer = bit_buffer & (1_u64.unsafe_shl(bit_count) &- 1)
      case problem
      when 1 then malformed("Invalid literal/length code")
      when 2 then malformed("Invalid distance code")
      when 3 then check_distance(@copy_distance)
      end
    end
  end
end
