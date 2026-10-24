class Mica::Reader
  # Returns the byte at the current position, or -1 at the end of the
  # current source.
  @[AlwaysInline]
  private def peek_byte : Int32
    return -1 if @pos >= @limit && !fill
    @buffer.unsafe_fetch(@pos).to_i32
  end

  # Returns the byte *offset* bytes ahead, or -1 past the end.
  @[AlwaysInline]
  private def peek_byte_at(offset : Int32) : Int32
    return -1 unless ensure_bytes(offset + 1)
    @buffer.unsafe_fetch(@pos + offset).to_i32
  end

  # Returns true when the input at the current position starts with
  # *literal*. Consumes nothing.
  private def starts_with?(literal : String) : Bool
    size = literal.bytesize
    return false unless ensure_bytes(size)
    (@buffer.to_unsafe + @pos).memcmp(literal.to_unsafe, size) == 0
  end

  # Consumes *literal* when the input starts with it.
  private def skip_literal?(literal : String) : Bool
    return false unless starts_with?(literal)
    @pos += literal.bytesize
    true
  end

  private def expect_literal(literal : String, context : String) : Nil
    return if skip_literal?(literal)
    syntax_error("Expected '#{literal}' #{context}")
  end

  private def expect_byte(byte : Char, context : String) : Nil
    if peek_byte == byte.ord
      @pos += 1
    else
      syntax_error("Expected '#{byte}' #{context}")
    end
  end

  # Skips white space and returns true when there was any.
  private def skip_spaces : Bool
    skipped = false
    loop do
      if @pos >= @limit
        break unless fill
      end
      byte = @buffer.unsafe_fetch(@pos)
      case byte
      when 0x20, 0x09
        @pos += 1
      when 0x0A
        @pos += 1
        newline
      when 0x0D
        @pos += 1
        if @in_document_source
          @pos += 1 if peek_byte == 0x0A
          newline
        end
      else
        break
      end
      skipped = true
    end
    skipped
  end

  private def require_spaces(context : String) : Nil
    syntax_error("Expected white space #{context}") unless skip_spaces
  end

  # Scans a Name and returns its start (relative to the mark) and size.
  private def scan_name_span : {Int32, Int32}
    start = @pos - @mark
    first = true
    loop do
      if @pos >= @limit
        break unless fill
      end
      byte = @buffer.unsafe_fetch(@pos)
      if byte < 0x80
        flags = CharClass.flags(byte)
        if first
          break if flags & CharClass::NAME_START == 0
        else
          break if flags & CharClass::NAME_CHAR == 0
        end
        @pos += 1
      else
        code, length = decode_at_pos
        if first
          break unless CharClass.name_start_char?(code)
        else
          break unless CharClass.name_char?(code)
        end
        @pos += length
      end
      first = false
    end
    size = @pos - @mark - start
    syntax_error("Expected a name") if size == 0
    if size > @options.max_name_bytes
      limit_error("Name exceeds max_name_bytes (#{@options.max_name_bytes})")
    end
    {start, size}
  end

  # Scans a Name and interns it.
  @[AlwaysInline]
  private def scan_name_id : Int32
    start, size = scan_name_span
    @names.intern(@buffer[@mark + start, size])
  end

  # Scans an Nmtoken (one or more NameChar) and returns its size.
  private def scan_nmtoken : Int32
    # Relative to the mark: a refill may compact the buffer.
    start = @pos - @mark
    loop do
      if @pos >= @limit
        break unless fill
      end
      byte = @buffer.unsafe_fetch(@pos)
      if byte < 0x80
        break if CharClass.flags(byte) & CharClass::NAME_CHAR == 0
        @pos += 1
      else
        code, length = decode_at_pos
        break unless CharClass.name_char?(code)
        @pos += length
      end
    end
    size = @pos - @mark - start
    syntax_error("Expected a name token") if size == 0
    size
  end

  # Decodes the non-ASCII UTF-8 sequence at the current position without
  # consuming it. Raises `Mica::EncodingError` for invalid UTF-8 and
  # `Mica::ParseError` for code points outside the XML Char production.
  private def decode_at_pos : {Int32, Int32}
    if @ascii_only
      encoding_error("Byte 0x#{@buffer[@pos].to_s(16)} is not valid in the declared US-ASCII encoding")
    end
    needed = CharClass.utf8_sequence_length(@buffer.unsafe_fetch(@pos))
    ensure_bytes(needed)
    code, length = CharClass.decode_utf8(@buffer.to_unsafe + @pos, @limit - @pos)
    if length <= 0
      encoding_error("Invalid UTF-8 byte sequence")
    end
    unless CharClass.xml_char?(code)
      syntax_error("Character U+#{code.to_s(16).upcase.rjust(4, '0')} is not allowed in XML")
    end
    {code, length}
  end

  # Reads one character (any byte value) at the current position, applying
  # line-end normalization in the document entity. Returns -1 at the end of
  # the source. Used by the DTD and literal scanners, which are not hot.
  private def next_char : Int32
    return -1 if @pos >= @limit && !fill
    byte = @buffer.unsafe_fetch(@pos)
    if byte < 0x80
      if byte < 0x20
        case byte
        when 0x0A
          @pos += 1
          newline
          return 0x0A
        when 0x0D
          @pos += 1
          if @in_document_source
            @pos += 1 if peek_byte == 0x0A
            newline
            return 0x0A
          end
          return 0x0D
        when 0x09
          @pos += 1
          return 0x09
        else
          syntax_error("Character U+#{byte.to_s(16).upcase.rjust(4, '0')} is not allowed in XML")
        end
      end
      @pos += 1
      return byte.to_i32
    end
    code, length = decode_at_pos
    @pos += length
    code
  end

  # Grows the scratch buffer to hold *extra* more bytes.
  @[AlwaysInline]
  private def reserve_scratch(extra : Int32) : Nil
    needed = @scratch_size + extra
    return if needed <= @scratch.size
    if needed.to_i64 > @options.max_token_bytes.to_i64 * 2 + TOKEN_SLACK
      limit_error("Token exceeds max_token_bytes (#{@options.max_token_bytes})")
    end
    capacity = @scratch.size
    while capacity < needed
      capacity *= 2
    end
    grown = Bytes.new(capacity)
    grown.copy_from(@scratch.to_unsafe, @scratch_size)
    @scratch = grown
  end

  # Appends input bytes `[mark + start, mark + start + size)` to scratch.
  @[AlwaysInline]
  private def append_input_to_scratch(start : Int32, size : Int32) : Nil
    return if size <= 0
    reserve_scratch(size)
    (@scratch.to_unsafe + @scratch_size).copy_from(@buffer.to_unsafe + @mark + start, size)
    @scratch_size += size
  end

  @[AlwaysInline]
  private def append_scratch_byte(byte : UInt8) : Nil
    reserve_scratch(1)
    @scratch.to_unsafe[@scratch_size] = byte
    @scratch_size += 1
  end

  private def append_scratch_bytes(bytes : Bytes) : Nil
    return if bytes.empty?
    reserve_scratch(bytes.size)
    (@scratch.to_unsafe + @scratch_size).copy_from(bytes.to_unsafe, bytes.size)
    @scratch_size += bytes.size
  end

  # Appends the UTF-8 encoding of *code* to scratch.
  private def append_scratch_char(code : Int32) : Nil
    reserve_scratch(4)
    ptr = @scratch.to_unsafe + @scratch_size
    if code < 0x80
      ptr[0] = code.to_u8
      @scratch_size += 1
    elsif code < 0x800
      ptr[0] = (0xC0 | (code >> 6)).to_u8
      ptr[1] = (0x80 | (code & 0x3F)).to_u8
      @scratch_size += 2
    elsif code < 0x10000
      ptr[0] = (0xE0 | (code >> 12)).to_u8
      ptr[1] = (0x80 | ((code >> 6) & 0x3F)).to_u8
      ptr[2] = (0x80 | (code & 0x3F)).to_u8
      @scratch_size += 3
    else
      ptr[0] = (0xF0 | (code >> 18)).to_u8
      ptr[1] = (0x80 | ((code >> 12) & 0x3F)).to_u8
      ptr[2] = (0x80 | ((code >> 6) & 0x3F)).to_u8
      ptr[3] = (0x80 | (code & 0x3F)).to_u8
      @scratch_size += 4
    end
  end

  private def check_token_size(size : Int32) : Nil
    if size > @options.max_token_bytes
      limit_error("Token exceeds max_token_bytes (#{@options.max_token_bytes})")
    end
  end
end
