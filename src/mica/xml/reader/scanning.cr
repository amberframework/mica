class Mica::XML::Reader
  private def expect_literal(literal : String, context : String) : Nil
    return if skip_literal?(literal)
    syntax_error("Expected '#{literal}' #{context}")
  end

  @[AlwaysInline]
  private def expect_byte(byte : Char, context : String) : Nil
    if peek_byte == byte.ord
      @pos += 1
    else
      syntax_error("Expected '#{byte}' #{context}")
    end
  end

  # Skips white space and returns true when there was any. In an XML 1.1
  # document entity, NEL and LSEP are line ends and so count as white
  # space.
  @[AlwaysInline]
  private def skip_spaces : Bool
    skipped = false
    loop do
      if @pos >= @limit
        break unless fill
      end
      # Checked by bytes: a line end can take up to three.
      scan_checkpoint if @pos - @mark - @token_precharged >= SCAN_CHUNK
      byte = @buffer[@pos]
      case byte
      when 0x20, 0x09
        @pos += 1
      when 0x0A
        @pos += 1
        newline
      when 0x0D
        @pos += 1
        if @in_document_source
          consume_line_end_after_cr
          newline
        end
      else
        break unless byte >= 0x80 && xml11_line_ends?
        length = xml11_line_end_length
        break if length == 0
        @pos += length
        newline
      end
      skipped = true
    end
    skipped
  end

  private def require_spaces(context : String) : Nil
    syntax_error("Expected white space #{context}") unless skip_spaces
  end

  # True when NEL and LSEP are line ends here: an XML 1.1 document, reading
  # the document entity (replacement text was normalized when declared).
  @[AlwaysInline]
  private def xml11_line_ends? : Bool
    @xml11 && @in_document_source
  end

  # Returns the byte length of a NEL (C2 85) or LSEP (E2 80 A8) at the
  # current position, or 0.
  private def xml11_line_end_length : Int32
    byte = @buffer[@pos]
    if byte == 0xC2
      return 2 if peek_byte_at(1) == 0x85
    elsif byte == 0xE2
      return 3 if peek_byte_at(1) == 0x80 && peek_byte_at(2) == 0xA8
    end
    0
  end

  # After a CR in the document entity, consumes the LF (or, in XML 1.1, the
  # NEL) that completes the line end.
  @[AlwaysInline]
  private def consume_line_end_after_cr : Nil
    next_byte = peek_byte
    if next_byte == 0x0A
      @pos += 1
    elsif next_byte == 0xC2 && @xml11 && peek_byte_at(1) == 0x85
      @pos += 2
    end
  end

  # Scans a Name and returns its start (relative to the mark) and size.
  @[AlwaysInline]
  private def scan_name_span : {Int32, Int32}
    start = @pos - @mark
    max_name_bytes = @options.max_name_bytes
    if (byte = peek_byte) >= 0 && byte < 0x80
      syntax_error("Expected a name") if CharClass.flags(byte.to_u8) & CharClass::NAME_START == 0
      name_limit_error("Name") if max_name_bytes < 1
      @pos += 1
    elsif byte >= 0x80
      code, length = decode_at_pos
      syntax_error("Expected a name") unless CharClass.name_start_char?(code)
      name_limit_error("Name") if length > max_name_bytes
      @pos += length
    end
    # Fast path: an ASCII name that ends inside the buffer, within
    # NAME_FAST_WINDOW bytes and the name limit, is scanned here; anything
    # else continues in `scan_name_chars`.
    buffer = @buffer
    index = @pos
    room = max_name_bytes - (index - @mark - start)
    window = room < NAME_FAST_WINDOW ? room : NAME_FAST_WINDOW
    stop = @limit - index > window ? index + window : @limit
    index = Core::ByteScan.skip_while(buffer, index, stop) { |next_byte| CharClass.flags(next_byte) & CharClass::NAME_CHAR != 0 }
    @pos = index
    scan_name_chars(start, "Name") if index == stop || buffer[index] >= 0x80
    size = @pos - @mark - start
    syntax_error("Expected a name") if size == 0
    {start, size}
  end

  # Bytes `scan_name_span` scans inline before handing a name to
  # `scan_name_chars`.
  private NAME_FAST_WINDOW = 256

  # Consumes NameChar characters of a name or name token that started at
  # *start* (relative to the mark).
  #
  # ASCII name characters are skipped in runs over a bounds-checked window
  # that ends at the name limit and at most SCAN_CHUNK bytes ahead, so the
  # budget is checked every chunk; non-ASCII characters are decoded and
  # checked one at a time. A name character that would take the name past
  # `max_name_bytes` raises, positioned at that character.
  private def scan_name_chars(start : Int32, what : String) : Nil
    max_name_bytes = @options.max_name_bytes
    loop do
      if @pos >= @limit
        break unless fill
      end
      consumed = @pos - @mark - start
      byte = @buffer[@pos]
      if byte < 0x80
        break if CharClass.flags(byte) & CharClass::NAME_CHAR == 0
        name_limit_error(what) if consumed >= max_name_bytes
        window = Math.min(Math.min(max_name_bytes - consumed, @limit - @pos), SCAN_CHUNK)
        stop = @pos + window
        buffer = @buffer
        index = Core::ByteScan.skip_while(buffer, @pos, stop) { |next_byte| CharClass.flags(next_byte) & CharClass::NAME_CHAR != 0 }
        @pos = index
        if index < stop
          # An ASCII byte ends the name; a non-ASCII byte is decoded next.
          break if buffer[index] < 0x80
        else
          scan_checkpoint
        end
      else
        code, length = decode_at_pos
        break unless CharClass.name_char?(code)
        name_limit_error(what) if consumed + length > max_name_bytes
        @pos += length
        scan_checkpoint if @pos - @mark - @token_precharged >= SCAN_CHUNK
      end
    end
  end

  private def name_limit_error(what : String) : NoReturn
    limit_error("#{what} exceeds max_name_bytes (#{@options.max_name_bytes})")
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
    scan_name_chars(start, "Name token")
    size = @pos - @mark - start
    syntax_error("Expected a name token") if size == 0
    size
  end

  # Decodes the non-ASCII UTF-8 sequence at the current position without
  # consuming it. Raises `Mica::EncodingError` for bytes that are not valid
  # in the input's encoding and `Mica::ParseError` for code points the
  # document's XML version does not allow literally.
  private def decode_at_pos : {Int32, Int32}
    lead = @buffer[@pos]
    if @ascii_only
      encoding_error("Byte 0x#{hex_byte(lead)} is not valid in the declared US-ASCII encoding")
    end
    ensure_bytes(Core::UTF8.sequence_length(lead))
    code, length = Core::UTF8.decode(@buffer, @pos, @limit)
    invalid_encoding(lead, code) if length == 0
    check_literal_char(code)
    {code, length}
  end

  private def invalid_encoding(lead : UInt8, problem_code : Int32) : NoReturn
    if marker = describe_transcoder_marker(lead)
      encoding_error(marker)
    end
    problem = Core::UTF8.problem(problem_code)
    encoding_error("Invalid UTF-8: #{problem.describe} at byte 0x#{hex_byte(lead)}")
  end

  # Raises unless *code* (from a non-ASCII sequence) may appear literally.
  # Replacement text of an internal entity may hold any Char of the
  # document's version: its restricted characters came from character
  # references, which were checked when the entity was declared.
  @[AlwaysInline]
  private def check_literal_char(code : Int32) : Nil
    return if code >= 0xA0 && code <= 0xD7FF
    if @xml11
      return if CharClass.xml11_literal_char?(code)
      if CharClass.xml11_char?(code)
        return unless @in_document_source
        syntax_error("Character U+#{hex_code(code)} must be written as a character reference in XML 1.1")
      end
    else
      return if CharClass.xml_char?(code)
    end
    syntax_error("Character U+#{hex_code(code)} is not allowed in XML")
  end

  # Handles an ASCII control byte that stopped a scan loop and consumes it
  # when it is allowed: DEL (0x7F) is a character in XML 1.0, and in XML 1.1
  # replacement text every control but NUL came from a character reference.
  # Everything else is an error.
  private def accept_ascii_control(byte : UInt8) : Nil
    if @xml11 && !@in_document_source && byte != 0
      @pos += 1
      return
    end
    if byte == 0x7F
      unless @xml11
        @pos += 1
        return
      end
      syntax_error("Character U+007F must be written as a character reference in XML 1.1")
    end
    syntax_error("Character U+#{hex_code(byte.to_i32)} is not allowed in XML")
  end

  private def hex_byte(byte : UInt8) : String
    byte.to_s(16).upcase.rjust(2, '0')
  end

  private def hex_code(code : Int32) : String
    code.to_s(16).upcase.rjust(4, '0')
  end

  # Reads one character (any byte value) at the current position, applying
  # line-end normalization in the document entity. Returns -1 at the end of
  # the source. Used by the DTD and literal scanners, which are not hot.
  private def next_char : Int32
    return -1 if @pos >= @limit && !fill
    # Checked by bytes, so multibyte characters cannot stretch the interval.
    scan_checkpoint if @pos - @mark - @token_precharged >= SCAN_CHUNK
    byte = @buffer[@pos]
    if byte < 0x80
      if byte < 0x20 || byte == 0x7F
        case byte
        when 0x0A
          @pos += 1
          newline
          return 0x0A
        when 0x0D
          @pos += 1
          if @in_document_source
            consume_line_end_after_cr
            newline
            return 0x0A
          end
          return 0x0D
        when 0x09
          @pos += 1
          return 0x09
        else
          accept_ascii_control(byte)
          return byte.to_i32
        end
      end
      @pos += 1
      return byte.to_i32
    end
    if xml11_line_ends?
      length = xml11_line_end_length
      if length > 0
        @pos += length
        newline
        return 0x0A
      end
    end
    code, length = decode_at_pos
    @pos += length
    code
  end

  # Copies into scratch at least this long are charged at once.
  private SCRATCH_CHARGE_NOW = 256

  # Grows the scratch buffer to hold *extra* more bytes.
  @[AlwaysInline]
  private def reserve_scratch(extra : Int32) : Nil
    needed = @scratch_size.to_i64 + extra
    return if needed <= @scratch.size
    # Sizes are computed in Int64 and capped at the largest buffer an
    # Int32 index can address, so a raised limit never overflows.
    limit = Math.min(@options.max_token_bytes.to_i64 * 2 + Core::ByteInput::TOKEN_SLACK, Int32::MAX.to_i64)
    if needed > limit
      limit_error("Token exceeds max_token_bytes (#{@options.max_token_bytes})")
    end
    capacity = @scratch.size.to_i64
    while capacity < needed
      capacity *= 2
    end
    capacity = Math.min(capacity, limit)
    # Growth copies what scratch holds (geometrically, so each byte a
    # bounded number of times): charged first.
    charge(@scratch_size)
    grown = Bytes.new(capacity.to_i32)
    grown.copy_from(@scratch[0, @scratch_size])
    @scratch = grown
  end

  # Appends input bytes `[mark + start, mark + start + size)` to scratch.
  @[AlwaysInline]
  private def append_input_to_scratch(start : Int32, size : Int32) : Nil
    return if size <= 0
    # The copy is charged before it happens; a short one joins the token's
    # pending work (charged within the token, like other in-token work).
    if size >= SCRATCH_CHARGE_NOW
      charge(size)
    else
      charge_in_token(size)
    end
    reserve_scratch(size)
    @scratch[@scratch_size, size].copy_from(@buffer[@mark + start, size])
    @scratch_size += size
  end

  @[AlwaysInline]
  private def append_scratch_byte(byte : UInt8) : Nil
    reserve_scratch(1)
    @scratch[@scratch_size] = byte
    @scratch_size += 1
  end

  private def append_scratch_bytes(bytes : Bytes) : Nil
    return if bytes.empty?
    reserve_scratch(bytes.size)
    @scratch[@scratch_size, bytes.size].copy_from(bytes)
    @scratch_size += bytes.size
  end

  # Appends the UTF-8 encoding of *code* to scratch.
  private def append_scratch_char(code : Int32) : Nil
    reserve_scratch(4)
    @scratch_size += Core::UTF8.encode(code, @scratch[@scratch_size, @scratch.size - @scratch_size])
  end

  private def check_token_size(size : Int32) : Nil
    if size > @options.max_token_bytes
      limit_error("Token exceeds max_token_bytes (#{@options.max_token_bytes})")
    end
  end
end
