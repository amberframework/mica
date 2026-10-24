class Mica::Reader
  # Bytes beyond `max_token_bytes` the buffer may hold for the markup that
  # surrounds a token (names, quotes, delimiters).
  private TOKEN_SLACK = 64 * 1024

  @encoding_problem : String? = nil

  # Picks the decoding path for in-memory input from its first bytes.
  private def setup_bytes(bytes : Bytes) : Nil
    if problem = signature_problem(bytes)
      @encoding_problem = problem
      return
    end
    if utf16_signature?(bytes)
      big_endian = bytes[0] == 0xFE
      @encoding = "UTF-16"
      setup_stream(UTF16Decoder.new(IO::Memory.new(bytes[2, bytes.size - 2], writable: false), big_endian))
      return
    end
    bytes = bytes[3, bytes.size - 3] if utf8_signature?(bytes)
    @buffer = bytes
    @limit = bytes.size
    @input_bytes = bytes.size.to_i64
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
    if utf16_signature?(prefix)
      big_endian = prefix[0] == 0xFE
      @encoding = "UTF-16"
      setup_stream(UTF16Decoder.new(io, big_endian, prefix[2, prefix.size - 2]))
      return
    end
    prefix = prefix[3, prefix.size - 3] if utf8_signature?(prefix)
    setup_stream(io)
    prefix.copy_to(@buffer)
    @limit = prefix.size
    @input_bytes = prefix.size.to_i64
  end

  private def setup_stream(io : IO) : Nil
    @io = io
    @io_eof = false
    @buffer = Bytes.new(INITIAL_BUFFER_SIZE)
    @limit = 0
  end

  private def utf8_signature?(bytes : Bytes) : Bool
    bytes.size >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
  end

  private def utf16_signature?(bytes : Bytes) : Bool
    return false if bytes.size < 2
    (bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE)
  end

  # Returns a description of an unsupported or malformed encoding signature,
  # or nil when the input is UTF-8 or UTF-16 with a byte order mark.
  private def signature_problem(bytes : Bytes) : String?
    return nil if bytes.size < 4
    b0, b1, b2, b3 = bytes[0], bytes[1], bytes[2], bytes[3]
    if (b0 == 0 && b1 == 0 && b2 == 0xFE && b3 == 0xFF) || (b0 == 0xFF && b1 == 0xFE && b2 == 0 && b3 == 0) ||
       (b0 == 0 && b1 == 0 && b2 == 0 && b3 == 0x3C) || (b0 == 0x3C && b1 == 0 && b2 == 0 && b3 == 0)
      "UTF-32 input is not supported; Mica decodes UTF-8 and UTF-16"
    elsif (b0 == 0 && b1 == 0x3C && b2 == 0 && b3 == 0x3F) || (b0 == 0x3C && b1 == 0 && b2 == 0x3F && b3 == 0)
      "UTF-16 input must begin with a byte order mark"
    elsif b0 == 0x4C && b1 == 0x6F && b2 == 0xA7 && b3 == 0x94
      "EBCDIC input is not supported; Mica decodes UTF-8 and UTF-16"
    end
  end

  # Makes at least one more byte available in the current source. Returns
  # false at the end of the source. Keeps every byte from `@mark` (and from
  # `@pin` when set), so offsets relative to the mark stay valid.
  private def fill : Bool
    io = @io
    return false if io.nil? || @io_eof
    keep = @mark
    pin = @pin
    keep = pin if pin >= 0 && pin < keep
    if keep > 0
      count = @limit - keep
      @buffer.to_unsafe.move_from(@buffer.to_unsafe + keep, count) if count > 0
      @base_offset += keep
      @pos -= keep
      @limit -= keep
      @mark -= keep
      @pin -= keep if pin >= 0
    end
    if @limit == @buffer.size
      if @buffer.size.to_i64 >= @options.max_token_bytes.to_i64 + TOKEN_SLACK
        limit_error("Token exceeds max_token_bytes (#{@options.max_token_bytes})")
      end
      grown = Bytes.new(@buffer.size * 2)
      grown.copy_from(@buffer.to_unsafe, @limit)
      @buffer = grown
    end
    read = io.read(@buffer[@limit, @buffer.size - @limit])
    if read == 0
      @io_eof = true
      return false
    end
    @limit += read
    @input_bytes += read
    check_input_size
    true
  end

  private def check_input_size : Nil
    if max = @options.max_input_bytes
      if @input_bytes > max
        limit_error("Input exceeds max_input_bytes (#{max})")
      end
    end
  end

  # Makes *count* bytes available from the current position. Returns false
  # when the source ends first.
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

  # Starts reading *entity*'s replacement text in place of the current
  # source.
  private def push_entity(entity : DTD::Entity) : Nil
    replacement = entity.replacement || raise Error.new("BUG: external entity pushed")
    if @frames.size >= @options.max_entity_depth
      limit_error("Entity references nested deeper than max_entity_depth (#{@options.max_entity_depth})")
    end
    if @current_entity == entity || @frames.any? { |frame| frame.entity == entity }
      syntax_error("Recursive reference to entity '#{@names[entity.name_id]}'")
    end
    charge_expansion(replacement.size)
    @frames << SourceFrame.new(@buffer, @pos, @limit, @mark, @pin, @io, @io_eof, @base_offset, @current_entity)
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
  private def charge_expansion(bytes : Int32) : Nil
    @expansion_count += 1
    @expansion_bytes += bytes
    if @expansion_count > @options.max_entity_expansions
      limit_error("Entity expansions exceed max_entity_expansions (#{@options.max_entity_expansions})")
    end
    if @expansion_bytes > @options.max_entity_expansion_bytes
      limit_error("Entity expansion exceeds max_entity_expansion_bytes (#{@options.max_entity_expansion_bytes})")
    end
  end

  # Records a line break that ends just before the current position.
  @[AlwaysInline]
  private def newline : Nil
    return unless @in_document_source
    @line += 1
    @line_start = @base_offset + @pos
  end

  # Returns `{line, column}` of the current position in the document
  # entity. Inside entity replacement text this is the position just after
  # the outermost reference.
  private def error_position : {Int32, Int32}
    buffer = @buffer
    pos = @pos
    base = @base_offset
    if frame = @frames.first?
      buffer = frame.buffer
      pos = frame.pos
      base = frame.base_offset
    end
    absolute = base + pos
    column = 1
    if @line_start >= base && @line_start <= absolute
      start = (@line_start - base).to_i32
      index = start
      while index < pos
        byte = buffer[index]
        column += 1 unless byte & 0xC0 == 0x80
        index += 1
      end
    else
      column = (absolute - @line_start).to_i32 + 1
    end
    {@line, column}
  end

  private def syntax_error(message : String) : NoReturn
    line, column = error_position
    raise ParseError.new(message, line, column)
  end

  private def limit_error(message : String) : NoReturn
    line, column = error_position
    raise LimitExceededError.new(message, line, column)
  end

  private def encoding_error(message : String) : NoReturn
    line, column = error_position
    raise EncodingError.new(message, line, column)
  end
end
