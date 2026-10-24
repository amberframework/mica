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
      check_normalized(value_bytes, "character content", value_position)
    when .cdata?
      check_normalized(value_bytes, "CDATA section", value_position)
    when .comment?
      check_normalized(value_bytes, "comment", value_position)
    when .processing_instruction?
      check_normalized_name(@name_id)
      check_normalized(value_bytes, "processing instruction", value_position)
    end
  end

  # The position where the current event's value starts: exact when the
  # value lies unchanged in the document's buffer, otherwise the start of
  # the token (or, inside entity replacement text, the reference).
  private def value_position : Core::Position
    start = @token_position || return error_position
    return start if !@frames.empty? || @value_in_scratch
    line = start.line
    column = start.column
    index = @mark
    stop = @mark + @value_start
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

  # Raises `NormalizationError` at *position* (default: here) unless
  # *bytes* are NFC and start with a non-composing character.
  private def check_normalized(bytes : Bytes, construct : String, position : Core::Position? = nil) : Nil
    return if bytes.empty?
    charge(bytes.size.to_i64 * NORMALIZATION_OPERATIONS_PER_BYTE)
    code, length = Core::UTF8.decode(bytes)
    if length > 0 && ComposingCharacters.includes?(code)
      raise NormalizationError.new("The #{construct} starts with the composing character U+#{hex_code(code)} (XML 1.1 section 2.13)", position || error_position)
    end
    text = String.new(bytes)
    return if text.unicode_normalized?(:nfc)
    raise NormalizationError.new("The #{construct} is not in Unicode Normalization Form C (XML 1.1 section 2.13)", position || error_position)
  end
end
