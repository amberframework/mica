module Mica::Core
  # Buffered input for a format's scanner, included into the scanner class so
  # the hot loops read the buffer through instance variables with no extra
  # indirection.
  #
  # The input is either a `Bytes` read in place or a stream (`IO`, possibly
  # a `Transcoder`) read into one growable buffer. The scanner keeps
  # everything from `@mark` (the start of the current token) and from
  # `@pin` (when set) in the buffer; `fill` compacts the bytes before them
  # and doubles the buffer only when one token needs it, up to the token
  # limit. Offsets held across a `fill` must therefore be relative to
  # `@mark`.
  #
  # Positions: `@base_offset + @pos` is the decoded (UTF-8) offset of the
  # current byte; `source_offset_at` maps it back to an offset in the
  # original input (a byte order mark included, transcoded bytes counted in
  # their source encoding).
  #
  # The including type implements the hooks below. Text formats also include
  # `LineTracking`; binary formats (CBOR) need only this module.
  module ByteInput
    # Initial size of the stream buffer.
    INITIAL_BUFFER_SIZE = 64 * 1024

    # Bytes beyond the token limit the buffer may hold for markup around a
    # token (delimiters, names, quotes).
    TOKEN_SLACK = 64 * 1024

    @buffer : Bytes = Bytes.empty
    @pos = 0
    @limit = 0
    @mark = 0
    @pin = -1
    @io : IO? = nil
    @io_eof = true
    @base_offset = 0_i64
    @input_bytes = 0_i64
    @source_prefix_bytes = 0_i64
    @transcoded_from : Encoding? = nil
    @transcode_origin = 0_i64
    @source_bytes_before_buffer = 0_i64

    # Returns the largest token, in bytes, the buffer must hold.
    private abstract def input_token_limit : Int32

    # Returns the cap on decoded input bytes, or nil.
    private abstract def input_size_limit : Int64?

    # Raises the format's positioned limit error.
    private abstract def input_limit_error(message : String) : NoReturn

    # Called before the bytes `@buffer[0, keep]` are discarded.
    private abstract def discarding_input(keep : Int32) : Nil

    # Called after *count* more decoded bytes arrived (for work accounting).
    private abstract def input_received(count : Int32) : Nil

    # Reads *bytes* in place; *prefix_bytes* source bytes (a byte order mark)
    # precede them in the original input.
    private def setup_in_memory(bytes : Bytes, prefix_bytes : Int32 = 0) : Nil
      @buffer = bytes
      @pos = 0
      @limit = bytes.size
      @io = nil
      @io_eof = true
      @source_prefix_bytes = prefix_bytes.to_i64
      @input_bytes = bytes.size.to_i64
      input_received(bytes.size)
    end

    # Reads from *io*, starting with the already-read source bytes in
    # *carried*.
    private def setup_stream(io : IO, carried : Bytes = Bytes.empty, prefix_bytes : Int32 = 0) : Nil
      @io = io
      @io_eof = false
      @buffer = Bytes.new(Math.max(INITIAL_BUFFER_SIZE, carried.size))
      carried.copy_to(@buffer)
      @pos = 0
      @limit = carried.size
      @source_prefix_bytes = prefix_bytes.to_i64
      @input_bytes = carried.size.to_i64
      input_received(carried.size)
    end

    # Reads the rest of the input, from the current position on, through a
    # `Transcoder` from *encoding*. Used after an in-band encoding
    # declaration names an encoding that is not UTF-8. Everything before the
    # current position must have been ASCII.
    private def switch_to_transcoder(encoding : Encoding) : Nil
      discarding_input(@pos)
      rest = @buffer[@pos, @limit - @pos]
      io = @io
      source = io || IO::Memory.new(rest, writable: false)
      carried = io ? rest.dup : Bytes.empty
      @input_bytes -= rest.size
      @base_offset += @pos
      @transcoded_from = encoding
      @transcode_origin = @base_offset
      @source_bytes_before_buffer = 0_i64
      transcoder = Transcoder.new(source, encoding, carried)
      @io = transcoder
      @io_eof = false
      @buffer = Bytes.new(INITIAL_BUFFER_SIZE)
      @pos = 0
      @limit = 0
      @mark = 0
      @pin = -1
    end

    # Makes at least one more byte available. Returns false at the end of
    # the source. Keeps every byte from `@mark` (and from `@pin` when set),
    # so offsets relative to the mark stay valid.
    private def fill : Bool
      io = @io
      return false if io.nil? || @io_eof
      keep = @mark
      pin = @pin
      keep = pin if pin >= 0 && pin < keep
      if keep > 0
        discard(keep)
        count = @limit - keep
        # Overlapping move inside one buffer: both ranges lie in
        # [0, @limit), which is within @buffer.size.
        @buffer.to_unsafe.move_from(@buffer.to_unsafe + keep, count) if count > 0
        @base_offset += keep
        @pos -= keep
        @limit -= keep
        @mark -= keep
        @pin -= keep if pin >= 0
      end
      if @limit == @buffer.size
        if @buffer.size.to_i64 >= input_token_limit.to_i64 + TOKEN_SLACK
          input_limit_error("Token exceeds the token size limit (#{input_token_limit} bytes)")
        end
        grown = Bytes.new(@buffer.size * 2)
        grown.copy_from(@buffer[0, @limit])
        @buffer = grown
      end
      read = io.read(@buffer[@limit, @buffer.size - @limit])
      if read == 0
        @io_eof = true
        return false
      end
      @limit += read
      @input_bytes += read
      input_received(read)
      check_input_size
      true
    end

    private def discard(keep : Int32) : Nil
      discarding_input(keep)
      if encoding = @transcoded_from
        from = @transcode_origin > @base_offset ? (@transcode_origin - @base_offset).to_i32 : 0
        if from < keep
          @source_bytes_before_buffer += Transcoder.source_size(encoding, @buffer[from, keep - from])
        end
      end
    end

    private def check_input_size : Nil
      if max = input_size_limit
        if @input_bytes > max
          input_limit_error("Input exceeds the input size limit (#{max} bytes)")
        end
      end
    end

    # Makes *count* bytes available from the current position. Returns
    # false when the source ends first.
    @[AlwaysInline]
    private def ensure_bytes(count : Int32) : Bool
      while @limit - @pos < count
        return false unless fill
      end
      true
    end

    # Returns true when the current source has no more bytes.
    @[AlwaysInline]
    private def at_source_end? : Bool
      @pos >= @limit && !fill
    end

    # Returns the byte at the current position, or -1 at the end.
    @[AlwaysInline]
    private def peek_byte : Int32
      return -1 if @pos >= @limit && !fill
      @buffer[@pos].to_i32
    end

    # Returns the byte *offset* bytes ahead, or -1 past the end.
    @[AlwaysInline]
    private def peek_byte_at(offset : Int32) : Int32
      return -1 unless ensure_bytes(offset + 1)
      @buffer[@pos + offset].to_i32
    end

    # Returns true when the input at the current position starts with
    # *literal*. Consumes nothing.
    private def starts_with?(literal : String) : Bool
      size = literal.bytesize
      return false unless ensure_bytes(size)
      @buffer[@pos, size] == literal.to_slice
    end

    # Consumes *literal* when the input starts with it.
    private def skip_literal?(literal : String) : Bool
      return false unless starts_with?(literal)
      @pos += literal.bytesize
      true
    end

    # Returns the offset in the original input of byte *pos* of *buffer*,
    # whose first byte is at decoded offset *base*.
    private def source_offset_at(buffer : Bytes, pos : Int32, base : Int64) : Int64
      absolute = base + pos
      encoding = @transcoded_from
      return @source_prefix_bytes + absolute if encoding.nil? || absolute <= @transcode_origin
      from = @transcode_origin > base ? (@transcode_origin - base).to_i32 : 0
      in_buffer = Transcoder.source_size(encoding, buffer[from, pos - from])
      @source_prefix_bytes + @transcode_origin + @source_bytes_before_buffer + in_buffer
    end
  end
end
