class Mica::XML::Reader
  # Results of `parse_content_reference`.
  private REFERENCE_INLINED = 0
  private REFERENCE_PUSH    = 1
  private REFERENCE_SKIPPED = 2

  # Parses a reference in content (the current byte is `&`). Character
  # references, predefined entities and text-only internal entities are
  # appended to scratch (returns REFERENCE_INLINED). An internal entity with
  # markup is stored in `@pending_entity` (REFERENCE_PUSH); an entity that is
  # not expanded is stored in `@pending_skipped_entity_id`
  # (REFERENCE_SKIPPED).
  private def parse_content_reference : Int32
    @pos += 1
    if peek_byte == '#'.ord
      append_scratch_char(parse_char_reference)
      return REFERENCE_INLINED
    end
    name_id = scan_name_id
    expect_byte(';', "to end the entity reference")
    if byte = predefined_entity_byte(name_id)
      append_scratch_byte(byte)
      return REFERENCE_INLINED
    end
    entity = @dtd.general_entities[name_id]?
    unless entity
      if undeclared_entity_allowed?
        @pending_skipped_entity_id = name_id
        return REFERENCE_SKIPPED
      end
      syntax_error("Entity '#{@names[name_id]}' is not declared")
    end
    if entity.unparsed?
      syntax_error("Unparsed entity '#{@names[name_id]}' cannot be referenced in content")
    end
    replacement = entity.replacement
    unless replacement
      # External parsed entities are never fetched; report the reference.
      @pending_skipped_entity_id = name_id
      return REFERENCE_SKIPPED
    end
    unless entity.has_markup?
      if @frames.size >= @options.max_entity_depth
        limit_error("Entity references nested deeper than max_entity_depth (#{@options.max_entity_depth})")
      end
      charge_expansion(replacement.size)
      # The copy into scratch is charged before it is made.
      charge(replacement.size)
      append_scratch_bytes(replacement)
      return REFERENCE_INLINED
    end
    @pending_entity = entity
    REFERENCE_PUSH
  end

  # Returns the character a predefined entity stands for, or nil.
  @[AlwaysInline]
  private def predefined_entity_byte(name_id : Int32) : UInt8?
    ids = @predefined_ids
    if name_id == ids[0]
      '<'.ord.to_u8
    elsif name_id == ids[1]
      '>'.ord.to_u8
    elsif name_id == ids[2]
      '&'.ord.to_u8
    elsif name_id == ids[3]
      '\''.ord.to_u8
    elsif name_id == ids[4]
      '"'.ord.to_u8
    end
  end

  # Returns true when an undeclared entity is a validity problem rather
  # than a well-formedness error (WFC: Entity Declared): the document is not
  # standalone and has an external subset or parameter-entity references.
  private def undeclared_entity_allowed? : Bool
    !@standalone && (@dtd.external_subset? || @parameter_entity_referenced)
  end

  # Parses `#123;` or `#x1F;` after the `&` and returns the code point.
  private def parse_char_reference : Int32
    @pos += 1
    hex = false
    if peek_byte == 'x'.ord
      hex = true
      @pos += 1
    end
    value = 0
    digits = 0
    too_large = false
    loop do
      digit = digit_value(peek_byte, hex)
      break if digit < 0
      value = value * (hex ? 16 : 10) + digit unless too_large
      too_large = true if value > 0x10FFFF
      digits += 1
      @pos += 1
      # Leading zeros make the digit run unbounded: keep it under the token
      # limit and charge it every chunk.
      if digits % SCAN_CHUNK == 0
        check_token_size(@pos - @mark)
        scan_checkpoint
      end
    end
    syntax_error("Malformed character reference") if digits == 0
    expect_byte(';', "to end the character reference")
    check_referenced_char(value, too_large)
    value
  end

  # A character reference must name a `Char` of the document's XML
  # version: XML 1.1 also allows the C0 and C1 controls except NUL.
  private def check_referenced_char(value : Int32, too_large : Bool) : Nil
    allowed = !too_large && (@xml11 ? CharClass.xml11_char?(value) : CharClass.xml_char?(value))
    syntax_error("Character reference to an illegal character") unless allowed
  end

  # Parses a reference inside an attribute value (the current byte is `&`)
  # and appends its normalized expansion to scratch.
  private def parse_attribute_reference : Nil
    @pos += 1
    if peek_byte == '#'.ord
      append_scratch_char(parse_char_reference)
      return
    end
    name_id = scan_name_id
    expect_byte(';', "to end the entity reference")
    expand_attribute_entity_reference(name_id)
  end

  private def expand_attribute_entity_reference(name_id : Int32) : Nil
    if byte = predefined_entity_byte(name_id)
      append_scratch_byte(byte)
      return
    end
    entity = @dtd.general_entities[name_id]?
    unless entity
      return if undeclared_entity_allowed?
      syntax_error("Entity '#{@names[name_id]}' is not declared")
    end
    if entity.unparsed?
      syntax_error("Unparsed entity '#{@names[name_id]}' cannot be referenced in an attribute value")
    end
    replacement = entity.replacement
    unless replacement
      syntax_error("External entity '#{@names[name_id]}' cannot be referenced in an attribute value")
    end
    expand_attribute_entity(entity, replacement)
  end

  # Appends *entity*'s replacement text to scratch with attribute-value
  # normalization, expanding nested references.
  private def expand_attribute_entity(entity : DTD::Entity, text : Bytes) : Nil
    if @attribute_entity_stack.includes?(entity)
      syntax_error("Recursive reference to entity '#{@names[entity.name_id]}'")
    end
    if @attribute_entity_stack.size >= @options.max_entity_depth
      limit_error("Entity references nested deeper than max_entity_depth (#{@options.max_entity_depth})")
    end
    charge_expansion(text.size)
    charge(text.size + @attribute_entity_stack.size)
    @attribute_entity_stack << entity
    index = 0
    size = text.size
    while index < size
      byte = text[index]
      case byte
      when '<'.ord
        syntax_error("Entity '#{@names[entity.name_id]}' puts '<' into an attribute value")
      when '&'.ord
        index = expand_reference_in_text(text, index)
        next
      when 0x09, 0x0A, 0x0D
        append_scratch_byte(0x20_u8)
      else
        append_scratch_byte(byte)
      end
      index += 1
    end
    @attribute_entity_stack.pop
  end

  # Expands the reference starting at `text[index]` (an `&`) inside entity
  # replacement text used in an attribute value. Returns the index after the
  # reference.
  private def expand_reference_in_text(text : Bytes, index : Int32) : Int32
    terminator = text.index(';'.ord.to_u8, index) || syntax_error("Malformed reference in entity replacement text")
    body = text[index + 1, terminator - index - 1]
    if body.size > 0 && body[0] == '#'.ord
      append_scratch_char(decode_char_reference_body(body))
    else
      syntax_error("Malformed reference in entity replacement text") if body.empty?
      expand_attribute_entity_reference(@names.intern(body))
    end
    terminator + 1
  end

  # Decodes the body of a character reference (`#123` or `#x1F`).
  private def decode_char_reference_body(body : Bytes) : Int32
    hex = body.size > 1 && body[1] == 'x'.ord
    digits = hex ? body[2, body.size - 2] : body[1, body.size - 1]
    syntax_error("Malformed character reference") if digits.empty?
    value = 0
    too_large = false
    digits.each do |byte|
      digit = digit_value(byte, hex)
      syntax_error("Malformed character reference") if digit < 0
      value = value * (hex ? 16 : 10) + digit unless too_large
      too_large = true if value > 0x10FFFF
    end
    check_referenced_char(value, too_large)
    value
  end

  # Returns the value of a decimal (or, with *hex*, hexadecimal) digit, or
  # -1.
  private def digit_value(byte : UInt8 | Int32, hex : Bool) : Int32
    code = byte.to_i32
    return code - '0'.ord if code >= '0'.ord && code <= '9'.ord
    return -1 unless hex
    return code - 'a'.ord + 10 if code >= 'a'.ord && code <= 'f'.ord
    return code - 'A'.ord + 10 if code >= 'A'.ord && code <= 'F'.ord
    -1
  end
end
