class Mica::XML::Reader
  # Picks the decoding path for in-memory input from its first bytes.
  private def setup_bytes(bytes : Bytes) : Nil
    if problem = signature_problem(bytes)
      @encoding_problem = problem
      return
    end
    if mark = Core::Encoding.from_byte_order_mark(bytes)
      encoding, size = mark
      @signature = encoding
      if encoding.utf16?
        @encoding = "UTF-16"
        transcoder = Core::Transcoder.new(IO::Memory.new(bytes[size, bytes.size - size], writable: false), encoding)
        setup_transcoded_stream(transcoder, size)
        return
      end
      setup_in_memory(bytes[size, bytes.size - size], size)
      return
    end
    setup_in_memory(bytes)
  end

  # Reads the first bytes of *io* to pick the decoding path.
  private def setup_io(io : IO) : Nil
    prefix = Bytes.new(4)
    count = 0
    while count < 4
      read = io.read(prefix[count, 4 - count])
      break if read == 0
      count += read
    end
    prefix = prefix[0, count]
    if problem = signature_problem(prefix)
      @encoding_problem = problem
      return
    end
    if mark = Core::Encoding.from_byte_order_mark(prefix)
      encoding, size = mark
      @signature = encoding
      rest = prefix[size, prefix.size - size]
      if encoding.utf16?
        @encoding = "UTF-16"
        setup_transcoded_stream(Core::Transcoder.new(io, encoding, rest), size)
        return
      end
      setup_stream(io, rest, size)
      return
    end
    setup_stream(io, prefix)
  end

  # Returns a description of an unsupported or malformed encoding signature
  # (XML 1.0 appendix F), or nil when the input starts as UTF-8 or as
  # UTF-16 with a byte order mark.
  private def signature_problem(bytes : Bytes) : String?
    return if bytes.size < 4
    b0, b1, b2, b3 = bytes[0], bytes[1], bytes[2], bytes[3]
    if (b0 == 0 && b1 == 0 && b2 == 0xFE && b3 == 0xFF) || (b0 == 0xFF && b1 == 0xFE && b2 == 0 && b3 == 0) ||
       (b0 == 0 && b1 == 0 && b2 == 0 && b3 == 0x3C) || (b0 == 0x3C && b1 == 0 && b2 == 0 && b3 == 0)
      "UTF-32 input is not supported; Mica::XML decodes UTF-8, UTF-16, ISO-8859-1 and US-ASCII"
    elsif (b0 == 0 && b1 == 0x3C && b2 == 0 && b3 == 0x3F) || (b0 == 0x3C && b1 == 0 && b2 == 0x3F && b3 == 0)
      "UTF-16 input must begin with a byte order mark"
    elsif b0 == 0x4C && b1 == 0x6F && b2 == 0xA7 && b3 == 0x94
      "EBCDIC input is not supported; Mica::XML decodes UTF-8, UTF-16, ISO-8859-1 and US-ASCII"
    end
  end

  # Starts reading *entity*'s replacement text in place of the current
  # source.
  private def push_entity(entity : DTD::Entity) : Nil
    replacement = entity.replacement || raise Error.new("BUG: external entity pushed")
    if @frames.size >= @options.max_entity_depth
      limit_error("Entity references nested deeper than max_entity_depth (#{@options.max_entity_depth})")
    end
    # Charges the outer bytes scanned so far in this token (callers between
    # tokens move the mark to the position first) and the frame scan below,
    # which max_entity_depth bounds.
    charge(@frames.size + @pos - @mark - @token_precharged)
    @token_precharged = 0
    if @current_entity == entity || @frames.any? { |frame| frame.entity == entity }
      syntax_error("Recursive reference to entity '#{@names[entity.name_id]}'")
    end
    charge_expansion(replacement.size)
    # The outer token ends at the reference (its bytes were just charged),
    # so the outer source resumes with its mark at the position.
    @frames << SourceFrame.new(@buffer, @pos, @limit, @pos, @pin, @io, @io_eof, @base_offset, @current_entity)
    @buffer = replacement
    @pos = 0
    @limit = replacement.size
    @mark = 0
    @pin = -1
    @io = nil
    @io_eof = true
    @base_offset = 0_i64
    @current_entity = entity
    @in_document_source = false
  end

  # Returns to the source that referenced the current entity.
  private def pop_entity : Nil
    frame = @frames.pop
    @buffer = frame.buffer
    @pos = frame.pos
    @limit = frame.limit
    @mark = frame.mark
    @pin = frame.pin
    @io = frame.io
    @io_eof = frame.io_eof
    @base_offset = frame.base_offset
    @current_entity = frame.entity
    @in_document_source = @frames.empty?
  end

  # Charges one expansion of *bytes* bytes against the configured limits.
  # Expanded bytes count as input units for the work budget.
  private def charge_expansion(bytes : Int32) : Nil
    @expansion_count += 1
    @expansion_bytes += bytes
    if @expansion_count > @options.max_entity_expansions
      limit_error("Entity expansions exceed max_entity_expansions (#{@options.max_entity_expansions})")
    end
    if @expansion_bytes > @options.max_entity_expansion_bytes
      limit_error("Entity expansion exceeds max_entity_expansion_bytes (#{@options.max_entity_expansion_bytes})")
    end
    @meter.add_units(bytes)
  end

  # Records a line break that ends just before the current position.
  @[AlwaysInline]
  private def newline : Nil
    return unless @in_document_source
    record_line_break(@base_offset + @pos)
  end

  # Returns the position of the current byte in the document entity. Inside
  # entity replacement text this is the position just after the outermost
  # reference.
  private def error_position : Core::Position
    buffer = @buffer
    pos = @pos
    base = @base_offset
    if frame = @frames.first?
      buffer = frame.buffer
      pos = frame.pos
      base = frame.base_offset
    end
    pos = pos.clamp(0, buffer.size)
    Core::Position.new(source_offset_at(buffer, pos, base), @line, column_at(buffer, pos, base))
  end

  private def syntax_error(message : String) : NoReturn
    charge_scanned_before_error
    raise ParseError.new(message, error_position)
  end

  private def limit_error(message : String) : NoReturn
    charge_scanned_before_error
    raise LimitExceededError.new(message, error_position)
  end

  private def encoding_error(message : String) : NoReturn
    charge_scanned_before_error
    raise EncodingError.new(message, error_position)
  end

  # Records the bytes of the failing token scanned since its last charge,
  # so the meter's count after an error reflects the work done. Nothing is
  # enforced: an error is being raised anyway.
  private def charge_scanned_before_error : Nil
    scanned = @pos - @mark - @token_precharged
    @meter.charge(scanned) if scanned > 0
    @token_precharged += scanned if scanned > 0
  end
end
