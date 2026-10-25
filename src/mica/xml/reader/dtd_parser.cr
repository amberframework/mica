class Mica::XML::Reader
  # Bounds recursion through nested content-model groups.
  private MAX_CONTENT_MODEL_DEPTH = 256

  # Parses `<!DOCTYPE Name ExternalID? [internal subset]? >`. The external
  # subset is recorded but never fetched.
  private def parse_doctype : Nil
    @doctype_seen = true
    @pos += 9
    require_spaces("after '<!DOCTYPE'")
    root_id = scan_declared_name_id
    if @options.namespace_aware? && !@names.qname?(root_id)
      syntax_error("DOCTYPE name '#{Core.excerpt(@names[root_id])}' is not a valid QName")
    end
    @dtd.root_name = @names[root_id]
    had_space = skip_spaces
    if starts_with?("SYSTEM") || starts_with?("PUBLIC")
      syntax_error("Expected white space before the external ID") unless had_space
      public_id, system_id = parse_external_id(require_system: true)
      @dtd.public_id = public_id
      @dtd.system_id = system_id
      skip_spaces
    end
    if peek_byte == '['.ord
      @pos += 1
      parse_internal_subset
      skip_spaces
    end
    expect_byte('>', "to close the DOCTYPE declaration")
    @node_type = Type::DOCUMENT_TYPE
    @name_id = root_id
    @namespace_uri_id = NameTable::EMPTY_ID
    @event_depth = 0
    @value_size = 0
  end

  # Parses declarations up to the `]` that closes the internal subset.
  private def parse_internal_subset : Nil
    @pin = @pos
    base_level = @frames.size
    loop do
      charge_token
      @mark = @pos
      if @pos >= @limit && !fill
        if @frames.size > base_level
          pop_entity
          next
        end
        syntax_error("Unterminated internal DTD subset")
      end
      next if skip_spaces
      case peek_byte
      when ']'.ord
        if @frames.size > base_level
          syntax_error("']' is not allowed inside a parameter entity")
        end
        size = @pos - @pin
        check_token_size(size)
        @dtd.internal_subset = String.new(@buffer[@pin, size])
        @pin = -1
        @pos += 1
        return
      when '%'.ord
        parse_parameter_entity_reference
      when '<'.ord
        parse_markup_declaration
      else
        syntax_error("Unexpected character in the internal DTD subset")
      end
    end
  end

  private def parse_markup_declaration : Nil
    if starts_with?("<!ENTITY")
      parse_entity_declaration
    elsif starts_with?("<!ATTLIST")
      parse_attlist_declaration
    elsif starts_with?("<!ELEMENT")
      parse_element_declaration
    elsif starts_with?("<!NOTATION")
      parse_notation_declaration
    elsif starts_with?("<!--")
      parse_comment
    elsif starts_with?("<?")
      parse_processing_instruction
    elsif starts_with?("<![")
      syntax_error("Conditional sections are not allowed in the internal DTD subset")
    else
      syntax_error("Unknown markup declaration")
    end
  end

  # True while declarations are being recorded. After a skipped parameter
  # entity, later ENTITY and ATTLIST declarations are not processed unless
  # the document is standalone (XML 1.0 section 5.1).
  private def processing_declarations? : Bool
    !@dtd.skipped_parameter_entity? || @standalone
  end

  # Parses `%name;` between declarations.
  private def parse_parameter_entity_reference : Nil
    @pos += 1
    name_id = scan_declared_name_id
    expect_byte(';', "to end the parameter-entity reference")
    @parameter_entity_referenced = true
    entity = @dtd.parameter_entities[name_id]?
    unless entity
      syntax_error("Parameter entity '%#{Core.excerpt(@names[name_id])};' is not declared") if @standalone
      @dtd.skipped_parameter_entity = true
      return
    end
    if entity.external?
      @dtd.skipped_parameter_entity = true
      return
    end
    push_entity(entity)
  end

  # Parses `<!ENTITY ...>` (general or parameter).
  private def parse_entity_declaration : Nil
    @pos += 8
    require_spaces("after '<!ENTITY'")
    parameter = false
    if peek_byte == '%'.ord
      @pos += 1
      require_spaces("after '%' in an entity declaration")
      parameter = true
    end
    name_id = scan_declared_name_id
    if @options.namespace_aware? && !@names.ncname?(name_id)
      syntax_error("Entity name '#{Core.excerpt(@names[name_id])}' must not contain a colon")
    end
    require_spaces("after the entity name")
    quote = peek_byte
    if quote == '"'.ord || quote == '\''.ord
      value = parse_entity_value(quote)
      if normalization_checked?
        check_normalized(value, "entity replacement text")
      end
      # Entity.new scans the text once for markup.
      charge(value.size)
      entity = DTD::Entity.new(name_id, value, nil, nil, nil, parameter)
    else
      public_id, system_id = parse_external_id(require_system: true)
      notation = nil
      had_space = skip_spaces
      if !parameter && starts_with?("NDATA")
        syntax_error("Expected white space before NDATA") unless had_space
        @pos += 5
        require_spaces("after NDATA")
        notation = @names[scan_declared_name_id]
      end
      entity = DTD::Entity.new(name_id, nil, system_id, public_id, notation, parameter)
    end
    skip_spaces
    expect_byte('>', "to close the entity declaration")
    return unless processing_declarations?
    table = parameter ? @dtd.parameter_entities : @dtd.general_entities
    return if table.has_key?(name_id)
    return if !parameter && predefined_entity_byte(name_id)
    table[name_id] = entity
  end

  # Parses a quoted EntityValue: character references are replaced,
  # general entity references are kept as written (they are expanded where
  # the entity is used), parameter-entity references are rejected (they are
  # not allowed inside declarations in the internal subset).
  private def parse_entity_value(quote : Int32) : Bytes
    @pos += 1
    value = IO::Memory.new
    loop do
      byte = peek_byte
      syntax_error("Unterminated entity value") if byte < 0
      if byte == quote
        @pos += 1
        break
      end
      case byte
      when '%'.ord
        syntax_error("Parameter-entity references are not allowed inside markup declarations in the internal subset")
      when '&'.ord
        if peek_byte_at(1) == '#'.ord
          @pos += 1
          value << parse_char_reference.chr
        else
          @pos += 1
          start, size = scan_name_span
          expect_byte(';', "to end the entity reference")
          value.write_byte('&'.ord.to_u8)
          value.write(@buffer[@mark + start, size])
          value.write_byte(';'.ord.to_u8)
        end
      else
        value << next_char.chr
      end
      check_token_size(value.bytesize)
    end
    value.to_slice
  end

  # Parses `SYSTEM "uri"` or `PUBLIC "pubid" "uri"`. With *require_system*
  # false (notations) the system literal after PUBLIC is optional.
  private def parse_external_id(require_system : Bool) : {String?, String?}
    if skip_literal?("SYSTEM")
      require_spaces("after SYSTEM")
      return {nil, parse_system_literal}
    end
    if skip_literal?("PUBLIC")
      require_spaces("after PUBLIC")
      public_id = parse_pubid_literal
      if require_system
        require_spaces("after the public identifier")
        return {public_id, parse_system_literal}
      end
      had_space = skip_spaces
      quote = peek_byte
      if had_space && (quote == '"'.ord || quote == '\''.ord)
        return {public_id, parse_system_literal}
      end
      return {public_id, nil}
    end
    syntax_error("Expected SYSTEM or PUBLIC")
  end

  private def parse_system_literal : String
    quote = peek_byte
    unless quote == '"'.ord || quote == '\''.ord
      syntax_error("Expected a quoted system identifier")
    end
    @pos += 1
    literal = String::Builder.new
    loop do
      byte = peek_byte
      syntax_error("Unterminated system identifier") if byte < 0
      if byte == quote
        @pos += 1
        break
      end
      literal << next_char.chr
      check_token_size(literal.bytesize)
    end
    literal.to_s
  end

  private def parse_pubid_literal : String
    quote = peek_byte
    unless quote == '"'.ord || quote == '\''.ord
      syntax_error("Expected a quoted public identifier")
    end
    @pos += 1
    literal = String::Builder.new
    loop do
      byte = peek_byte
      syntax_error("Unterminated public identifier") if byte < 0
      if byte == quote
        @pos += 1
        break
      end
      code = next_char
      syntax_error("Invalid character in public identifier") unless CharClass.pubid_char?(code)
      literal << code.chr
      check_token_size(literal.bytesize)
    end
    literal.to_s
  end

  # Parses `<!ATTLIST element (name type default)*>`.
  private def parse_attlist_declaration : Nil
    @pos += 9
    require_spaces("after '<!ATTLIST'")
    element_id = scan_declared_name_id
    loop do
      had_space = skip_spaces
      byte = peek_byte
      if byte == '>'.ord
        @pos += 1
        break
      end
      syntax_error("Unterminated ATTLIST declaration") if byte < 0
      syntax_error("Expected white space before an attribute definition") unless had_space
      attr_id = scan_declared_name_id
      require_spaces("after the attribute name")
      type = parse_attribute_type
      require_spaces("after the attribute type")
      default_kind, default_value = parse_default_declaration(type)
      check_normalized(default_value, "attribute default value") if normalization_checked?
      record_attribute_declaration(element_id, DTD::AttributeDecl.new(attr_id, type, default_kind, default_value))
    end
  end

  private def record_attribute_declaration(element_id : Int32, decl : DTD::AttributeDecl) : Nil
    return unless processing_declarations?
    charge(1)
    @dtd.add_attribute_declaration(element_id, decl)
  end

  private def parse_attribute_type : DTD::AttributeType
    if peek_byte == '('.ord
      parse_enumeration(notation: false)
      return DTD::AttributeType::ENUMERATION
    end
    start, size = scan_name_span
    bytes = @buffer[@mark + start, size]
    # Only a keyword-sized name is copied; a longer one is unknown.
    keyword = size <= "NMTOKENS".bytesize ? String.new(bytes) : ""
    case keyword
    when "CDATA"    then DTD::AttributeType::CDATA
    when "ID"       then DTD::AttributeType::ID
    when "IDREF"    then DTD::AttributeType::IDREF
    when "IDREFS"   then DTD::AttributeType::IDREFS
    when "ENTITY"   then DTD::AttributeType::ENTITY
    when "ENTITIES" then DTD::AttributeType::ENTITIES
    when "NMTOKEN"  then DTD::AttributeType::NMTOKEN
    when "NMTOKENS" then DTD::AttributeType::NMTOKENS
    when "NOTATION"
      require_spaces("after NOTATION")
      parse_enumeration(notation: true)
      DTD::AttributeType::NOTATION
    else
      syntax_error("Unknown attribute type '#{Core.excerpt(bytes)}'")
    end
  end

  # Parses `( a | b | c )`: names for NOTATION, name tokens otherwise.
  private def parse_enumeration(notation : Bool) : Nil
    expect_byte('(', "to open the enumeration")
    loop do
      skip_spaces
      start = @pos - @mark
      if notation
        scan_name_span
      else
        scan_nmtoken
      end
      check_declared_name(start, notation ? "name" : "name token") if normalization_checked?
      skip_spaces
      case peek_byte
      when '|'.ord
        @pos += 1
      when ')'.ord
        @pos += 1
        return
      else
        syntax_error("Expected '|' or ')' in the enumeration")
      end
    end
  end

  private def parse_default_declaration(type : DTD::AttributeType) : {DTD::DefaultKind, Bytes}
    return {DTD::DefaultKind::REQUIRED, Bytes.empty} if skip_literal?("#REQUIRED")
    return {DTD::DefaultKind::IMPLIED, Bytes.empty} if skip_literal?("#IMPLIED")
    kind = DTD::DefaultKind::VALUE
    if skip_literal?("#FIXED")
      require_spaces("after #FIXED")
      kind = DTD::DefaultKind::FIXED
    end
    quote = peek_byte
    unless quote == '"'.ord || quote == '\''.ord
      syntax_error("Expected a quoted default value")
    end
    saved_scratch = @scratch_size
    start, size, in_scratch = scan_attribute_value(quote.to_u8)
    raw = in_scratch ? @scratch[start, size] : @buffer[@mark + start, size]
    value = type.cdata? ? raw.dup : collapse_spaces(raw)
    @scratch_size = saved_scratch
    {kind, value}
  end

  # Collapses runs of spaces to one and trims both ends.
  private def collapse_spaces(raw : Bytes) : Bytes
    charge(raw.size)
    io = IO::Memory.new(raw.size)
    pending_space = false
    raw.each do |byte|
      if byte == 0x20
        pending_space = io.pos > 0
      else
        io.write_byte(0x20_u8) if pending_space
        pending_space = false
        io.write_byte(byte)
      end
    end
    io.to_slice
  end

  # Parses `<!ELEMENT name contentspec>` for well-formedness.
  private def parse_element_declaration : Nil
    @pos += 9
    require_spaces("after '<!ELEMENT'")
    scan_declared_name_id
    require_spaces("after the element name")
    if peek_byte == '('.ord
      parse_content_model
    else
      start, size = scan_name_span
      keyword = String.new(@buffer[@mark + start, size])
      unless keyword == "EMPTY" || keyword == "ANY"
        syntax_error("Expected EMPTY, ANY or a content model")
      end
    end
    skip_spaces
    expect_byte('>', "to close the element declaration")
  end

  private def parse_content_model : Nil
    @pos += 1
    skip_spaces
    if skip_literal?("#PCDATA")
      parse_mixed_content
      return
    end
    parse_content_group(1)
    skip_content_modifier
  end

  # Parses the rest of `(#PCDATA | a | b)*` or `(#PCDATA)`.
  private def parse_mixed_content : Nil
    names = 0
    loop do
      skip_spaces
      case peek_byte
      when '|'.ord
        @pos += 1
        skip_spaces
        scan_declared_name_span
        names += 1
      when ')'.ord
        @pos += 1
        if names > 0
          expect_byte('*', "after a mixed content model with element names")
        else
          @pos += 1 if peek_byte == '*'.ord
        end
        return
      else
        syntax_error("Expected '|' or ')' in a mixed content model")
      end
    end
  end

  # Parses the members of a choice or sequence after its `(`.
  private def parse_content_group(depth : Int32) : Nil
    if depth > MAX_CONTENT_MODEL_DEPTH
      limit_error("Content model nested deeper than #{MAX_CONTENT_MODEL_DEPTH}")
    end
    separator = 0
    loop do
      skip_spaces
      if peek_byte == '('.ord
        @pos += 1
        parse_content_group(depth + 1)
      else
        scan_declared_name_span
      end
      skip_content_modifier
      skip_spaces
      byte = peek_byte
      if byte == ')'.ord
        @pos += 1
        return
      elsif byte == '|'.ord || byte == ','.ord
        if separator == 0
          separator = byte
        elsif separator != byte
          syntax_error("A content model group cannot mix ',' and '|'")
        end
        @pos += 1
      else
        syntax_error("Expected ',', '|' or ')' in a content model")
      end
    end
  end

  private def skip_content_modifier : Nil
    byte = peek_byte
    @pos += 1 if byte == '?'.ord || byte == '*'.ord || byte == '+'.ord
  end

  # Parses `<!NOTATION name (ExternalID | PublicID)>`.
  private def parse_notation_declaration : Nil
    @pos += 10
    require_spaces("after '<!NOTATION'")
    name_id = scan_declared_name_id
    if @options.namespace_aware? && !@names.ncname?(name_id)
      syntax_error("Notation name '#{Core.excerpt(@names[name_id])}' must not contain a colon")
    end
    require_spaces("after the notation name")
    public_id, system_id = parse_external_id(require_system: false)
    skip_spaces
    expect_byte('>', "to close the notation declaration")
    name = @names[name_id]
    @dtd.notations[name] = {public_id, system_id} unless @dtd.notations.has_key?(name)
  end

  # Reads a Name in a declaration. Under XML 1.1 normalization checking
  # the name is verified as it is read: section 2.13 lists every Name as a
  # relevant construct, so names in unused declarations are checked too.
  # An error points at the offending character of the name.
  private def scan_declared_name_id : Int32
    # Relative to the mark, which a refill keeps in the buffer.
    start = @pos - @mark
    name_id = scan_name_id
    if normalization_checked? && !@normalized_name_ids.includes?(name_id)
      check_declared_name(start)
      @normalized_name_ids << name_id
    end
    name_id
  end

  # Same for a name read as a span (relative to `@mark`).
  private def scan_declared_name_span : {Int32, Int32}
    start = @pos - @mark
    span = scan_name_span
    check_declared_name(start) if normalization_checked?
    span
  end

  # Checks the name (or name token) from *start* (relative to `@mark`) to
  # the current position.
  private def check_declared_name(start : Int32, construct : String = "name") : Nil
    first = @mark + start
    check_normalized(@buffer[first, @pos - first], construct, nil) do |offending|
      # Inside parameter-entity text, positions refer to the reference.
      @frames.empty? ? buffer_position(first + offending) : error_position
    end
  end
end
