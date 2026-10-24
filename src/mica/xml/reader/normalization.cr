class Mica::XML::Reader
  # Operations charged per byte checked for full normalization: the NFC
  # quick check, and for "maybe" results a decomposition and recomposition.
  NORMALIZATION_OPERATIONS_PER_BYTE = 8

  # Verifies XML 1.1 full normalization (section 2.13) for the event just
  # read: names, attribute values, character content, CDATA sections,
  # comments and processing instructions must be in Unicode NFC and must
  # not start with a composing character.
  #
  # Each text event is one relevant construct: text is split at markup and
  # at entity boundaries (each parsed entity is itself a relevant
  # construct), and character references are already expanded. The DTD
  # parser checks internal entity replacement text, attribute default
  # values, enumeration name tokens and declared names as it reads them,
  # so unused declarations are checked too.
  private def verify_normalization : Nil
    case @node_type
    when .element?
      check_normalized_name(@name_id)
      @attrs.each do |slot|
        check_normalized_name(slot.name_id)
        check_normalized(attribute_value_bytes(slot), "attribute value")
      end
    when .text?, .significant_whitespace?
      check_normalized_value("character content")
    when .cdata?
      check_normalized_value("CDATA section")
    when .comment?
      check_normalized_value("comment")
    when .processing_instruction?
      check_normalized_name(@name_id)
      check_normalized_value("processing instruction")
    end
  end

  # The position where the current event's value starts: exact when the
  # value lies unchanged in the document's buffer, otherwise the start of
  # the token (or, inside entity replacement text, the reference).
  private def value_position : Core::Position
    start = @token_position || return error_position
    return start unless value_in_buffer?
    position_after(start, @mark, @mark + @value_start)
  end

  # True when the current value is the bytes `@buffer[@mark + @value_start,
  # size]`, unchanged from the source, so positions inside it are exact.
  private def value_in_buffer? : Bool
    @frames.empty? && !@value_in_scratch && !@token_position.nil?
  end

  # Returns *start* (the position of buffer byte *index*) advanced over the
  # buffer bytes from *index* to *stop*.
  private def position_after(start : Core::Position, index : Int32, stop : Int32) : Core::Position
    line = start.line
    column = start.column
    while index < stop
      byte = @buffer[index]
      if byte == 0x0A || (byte == 0x0D && !(index + 1 < stop && @buffer[index + 1] == 0x0A))
        line += 1
        column = 1
      elsif byte & 0xC0 != 0x80 && byte != 0x0D
        column += 1
      end
      index += 1
    end
    Core::Position.new(source_offset_at(@buffer, stop, @base_offset), line, column)
  end

  # Where the current token started (set only while normalization is
  # checked).
  @token_position : Core::Position? = nil

  # True when XML 1.1 full normalization is being checked (an XML 1.1
  # document read with `check_normalization`); set from the XML
  # declaration.
  @normalization_checked = false

  @[AlwaysInline]
  private def normalization_checked? : Bool
    @normalization_checked
  end

  private def check_normalized_name(name_id : Int32) : Nil
    return if @normalized_name_ids.includes?(name_id)
    check_normalized(@names[name_id].to_slice, "name", @token_position || error_position)
    @normalized_name_ids << name_id
  end

  # Checks the current event's value; an error points at the offending
  # character when the value lies unchanged in the buffer.
  private def check_normalized_value(construct : String) : Nil
    bytes = value_bytes
    start = value_position
    return check_normalized(bytes, construct, start) unless value_in_buffer?
    value_index = @mark + @value_start
    check_normalized(bytes, construct, start) do |offending|
      position_after(start, value_index, value_index + offending)
    end
  end

  # Raises `NormalizationError` at *position* (default: here) unless
  # *bytes* are NFC and start with a non-composing character.
  private def check_normalized(bytes : Bytes, construct : String, position : Core::Position? = nil) : Nil
    check_normalized(bytes, construct, position) { position || error_position }
  end

  # Same; on failure the block gets the byte index in *bytes* of the
  # offending character and returns the position to report.
  private def check_normalized(bytes : Bytes, construct : String, position : Core::Position?, & : Int32 -> Core::Position) : Nil
    return if bytes.empty?
    charge(bytes.size.to_i64 * NORMALIZATION_OPERATIONS_PER_BYTE)
    code, length = Core::UTF8.decode(bytes)
    if length > 0 && ComposingCharacters.includes?(code)
      raise NormalizationError.new("The #{construct} starts with the composing character U+#{hex_code(code)} (XML 1.1 section 2.13)", position || error_position)
    end
    return if String.new(bytes).unicode_normalized?(:nfc)
    raise NormalizationError.new("The #{construct} is not in Unicode Normalization Form C (XML 1.1 section 2.13)", yield offending_normalization_index(bytes))
  end

  # Returns the byte index of the character that makes *bytes* (known not
  # to be NFC) fail: the bytes are split into segments of one
  # non-composing character and the composing characters after it, and the
  # first segment that is not NFC on its own is blamed. Within it, the
  # first composing character is blamed when the leading character alone
  # is NFC, otherwise the leading character. One pass, linear in the size.
  private def offending_normalization_index(bytes : Bytes) : Int32
    index = 0
    while index < bytes.size
      segment_start = index
      _, length = Core::UTF8.decode(bytes, index, bytes.size)
      index += Math.max(length, 1)
      first_composing = index
      while index < bytes.size
        code, length = Core::UTF8.decode(bytes, index, bytes.size)
        break unless length > 0 && ComposingCharacters.includes?(code)
        index += length
      end
      next if String.new(bytes[segment_start, index - segment_start]).unicode_normalized?(:nfc)
      return segment_start if first_composing == index
      return segment_start unless String.new(bytes[segment_start, first_composing - segment_start]).unicode_normalized?(:nfc)
      return first_composing
    end
    0
  end
end
