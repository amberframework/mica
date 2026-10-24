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
  # construct), and character references are already expanded.
  private def verify_normalization : Nil
    case @node_type
    when .element?
      check_normalized_name(@name_id)
      @attrs.each do |slot|
        check_normalized_name(slot.name_id)
        check_normalized(attribute_value_bytes(slot), "attribute value")
      end
    when .text?, .significant_whitespace?
      check_normalized(value_bytes, "character content")
    when .cdata?
      check_normalized(value_bytes, "CDATA section")
    when .comment?
      check_normalized(value_bytes, "comment")
    when .processing_instruction?
      check_normalized_name(@name_id)
      check_normalized(value_bytes, "processing instruction")
    end
  end

  private def check_normalized_name(name_id : Int32) : Nil
    return if @normalized_name_ids.includes?(name_id)
    check_normalized(@names[name_id].to_slice, "name")
    @normalized_name_ids << name_id
  end

  private def check_normalized(bytes : Bytes, construct : String) : Nil
    return if bytes.empty?
    charge(bytes.size.to_i64 * NORMALIZATION_OPERATIONS_PER_BYTE)
    code, length = Core::UTF8.decode(bytes)
    if length > 0 && ComposingCharacters.includes?(code)
      raise NormalizationError.new("The #{construct} ending here starts with the composing character U+#{hex_code(code)} (XML 1.1 section 2.13)", error_position)
    end
    text = String.new(bytes)
    return if text.unicode_normalized?(:nfc)
    raise NormalizationError.new("The #{construct} ending here is not in Unicode Normalization Form C (XML 1.1 section 2.13)", error_position)
  end
end
