class Mica::XML::Reader
  # Bytes a scan loop examines between work-budget checks, so one long token
  # cannot run far past the budget or the deadline.
  private SCAN_CHUNK = 64 * 1024

  # Operations already charged inside the current token by `scan_checkpoint`.
  @token_precharged = 0

  # Produces the next event. Returns false at the end of the document.
  private def advance : Bool
    if @pending_binding_mark >= 0
      pop_bindings(@pending_binding_mark)
      @pending_binding_mark = -1
    end
    @scratch_size = 0
    @value_size = 0
    @value_in_scratch = false
    @empty_element = false
    @attrs.clear
    @attribute_lookup.clear unless @attribute_lookup.empty?
    # The previous event is finished: nothing before the position is needed.
    @mark = @pos
    @token_precharged = 0
    if entity = @pending_entity
      @pending_entity = nil
      push_entity(entity)
    end
    if @pending_skipped_entity_id >= 0
      emit_skipped_entity(@pending_skipped_entity_id)
      @pending_skipped_entity_id = -1
      return true
    end
    loop do
      @mark = @pos
      @token_precharged = 0
      if @pos >= @limit && !fill
        if @frames.empty?
          finish_document
          return false
        end
        leave_entity
        next
      end
      produced = @phase.content? ? content_token : misc_token
      charge_token
      return true if produced
    end
  end

  # Charges the bytes of the current token not yet charged (see
  # `charge_token`) and checks the budget, partway through a long scan.
  private def scan_checkpoint : Nil
    scanned = @pos - @mark - @token_precharged
    return if scanned <= 0
    @token_precharged += scanned
    charge(scanned)
  end

  # Ends the current entity's replacement text. Elements opened inside it
  # must be closed inside it.
  private def leave_entity : Nil
    if level = @open_entity_levels.last?
      if level == @frames.size
        syntax_error("Entity '#{entity_name}' ends inside element '#{@names[@open_names.last]}'")
      end
    end
    pop_entity
  end

  private def entity_name : String
    if entity = @current_entity
      @names[entity.name_id]
    else
      ""
    end
  end

  # Reads one token inside the root element.
  private def content_token : Bool
    byte = @buffer[@pos]
    return scan_text unless byte == '<'.ord
    case peek_byte_at(1)
    when '/'.ord
      parse_end_tag
    when '!'.ord
      if starts_with?("<!--")
        parse_comment
      elsif starts_with?("<![CDATA[")
        parse_cdata
      else
        syntax_error("Unexpected markup in content")
      end
    when '?'.ord
      parse_processing_instruction
    when -1
      syntax_error("Unexpected end of input after '<'")
    else
      parse_start_tag
    end
    true
  end

  # Parses a start tag or empty-element tag.
  private def parse_start_tag : Nil
    @pos += 1
    name_id = scan_name_id
    loop do
      had_space = skip_spaces
      byte = peek_byte
      if byte == '>'.ord
        @pos += 1
        break
      elsif byte == '/'.ord
        @pos += 1
        expect_byte('>', "to close the empty-element tag")
        @empty_element = true
        break
      elsif byte < 0
        syntax_error("Unexpected end of input in start tag '#{@names[name_id]}'")
      end
      syntax_error("Expected white space between attributes") unless had_space
      parse_attribute(name_id)
      scan_checkpoint
    end
    apply_attribute_declarations(name_id)
    if @options.namespace_aware?
      binding_mark = process_namespaces(name_id)
    else
      binding_mark = @binding_prefixes.size
      @namespace_uri_id = NameTable::EMPTY_ID
    end
    @node_type = Type::ELEMENT
    @name_id = name_id
    @event_depth = @open_names.size
    if @empty_element
      @pending_binding_mark = binding_mark
      @phase = Phase::Epilog if @open_names.empty?
    else
      if @open_names.size >= @options.max_element_depth
        limit_error("Elements nested deeper than max_element_depth (#{@options.max_element_depth})")
      end
      @open_names << name_id
      @open_namespace_uris << @namespace_uri_id
      @open_binding_marks << binding_mark
      @open_entity_levels << @frames.size
    end
  end

  # Parses `Name Eq AttValue` and records it.
  private def parse_attribute(element_id : Int32) : Nil
    if @attrs.size >= @options.max_attributes
      limit_error("Element has more than max_attributes (#{@options.max_attributes}) attributes")
    end
    attr_id = scan_name_id
    skip_spaces
    expect_byte('=', "after attribute name '#{@names[attr_id]}'")
    skip_spaces
    quote = peek_byte
    unless quote == '"'.ord || quote == '\''.ord
      syntax_error("Expected a quoted value for attribute '#{@names[attr_id]}'")
    end
    start, size, in_scratch = scan_attribute_value(quote.to_u8)
    check_duplicate_attribute(attr_id)
    @attrs << AttributeSlot.new(attr_id, start, size, in_scratch, NameTable::EMPTY_ID, true)
  end

  private def check_duplicate_attribute(attr_id : Int32) : Nil
    if find_attribute_slot(attr_id)
      syntax_error("Attribute '#{@names[attr_id]}' appears twice")
    end
  end

  # Elements with more attributes than this are indexed by a hash so that
  # duplicate checks and lookups stay linear.
  private LINEAR_ATTRIBUTE_SCAN = 16

  # Returns the slot index of attribute *name_id* on the current start tag.
  # Costs at most LINEAR_ATTRIBUTE_SCAN comparisons, or one hash lookup
  # plus the amortized cost of indexing each attribute once.
  private def find_attribute_slot(name_id : Int32) : Int32?
    count = @attrs.size
    if count <= LINEAR_ATTRIBUTE_SCAN
      charge(count)
      index = 0
      while index < count
        return index if @attrs[index].name_id == name_id
        index += 1
      end
      return
    end
    charge(count - @attribute_lookup.size + 1)
    while @attribute_lookup.size < count
      position = @attribute_lookup.size
      @attribute_lookup[@attrs[position].name_id] = position
    end
    @attribute_lookup[name_id]?
  end

  # Scans an attribute value after its opening quote, normalizing white
  # space and expanding references (XML 1.0 section 3.3.3, CDATA rules).
  # Returns `{start, size, in_scratch}`.
  private def scan_attribute_value(quote : UInt8) : {Int32, Int32, Bool}
    @pos += 1
    start = @pos - @mark
    segment = start
    in_scratch = false
    scratch_start = @scratch_size
    loop do
      # Hot loop: `Slice#index` walks a bounds-checked window of at most
      # SCAN_CHUNK bytes.
      pos = @pos
      limit = @limit
      stop = limit - pos > SCAN_CHUNK ? pos + SCAN_CHUNK : limit
      found = @buffer[pos, stop - pos].index { |byte| CharClass.flags(byte) & CharClass::ATTR_STOP != 0 }
      pos = found ? pos + found : stop
      @pos = pos
      if pos >= stop
        if pos < limit
          scan_checkpoint
          next
        end
        syntax_error("Unterminated attribute value") unless fill
        next
      end
      byte = @buffer[pos]
      if byte == quote
        break
      end
      case byte
      when '"'.ord, '\''.ord
        @pos += 1
      when '<'.ord
        syntax_error("'<' is not allowed in attribute values")
      when '&'.ord
        in_scratch = true
        append_input_to_scratch(segment, @pos - @mark - segment)
        parse_attribute_reference
        segment = @pos - @mark
      when 0x09, 0x0A, 0x0D
        in_scratch = true
        append_input_to_scratch(segment, @pos - @mark - segment)
        append_scratch_byte(0x20_u8)
        @pos += 1
        if byte == 0x0D && @in_document_source
          consume_line_end_after_cr
          newline
        elsif byte == 0x0A
          newline
        end
        segment = @pos - @mark
      else
        if byte < 0x80
          accept_ascii_control(byte)
          next
        end
        if xml11_line_ends? && (length = xml11_line_end_length) > 0
          in_scratch = true
          append_input_to_scratch(segment, @pos - @mark - segment)
          append_scratch_byte(0x20_u8)
          @pos += length
          newline
          segment = @pos - @mark
          next
        end
        _, length = decode_at_pos
        @pos += length
      end
    end
    end_offset = @pos - @mark
    @pos += 1
    if in_scratch
      append_input_to_scratch(segment, end_offset - segment)
      size = @scratch_size - scratch_start
      check_token_size(size)
      {scratch_start, size, true}
    else
      check_token_size(end_offset - start)
      {start, end_offset - start, false}
    end
  end

  # Applies `<!ATTLIST>` information to the current start tag: defaults for
  # missing attributes and token normalization for non-CDATA types. The work
  # is proportional to the attributes present plus the defaults added, never
  # to the number of declarations (an element type can declare thousands of
  # #IMPLIED attributes).
  private def apply_attribute_declarations(element_id : Int32) : Nil
    return unless @dtd.declares_attributes?(element_id)
    present = @attrs.size
    charge(present)
    index = 0
    while index < present
      if decl = @dtd.attribute_declaration(element_id, @attrs[index].name_id)
        normalize_tokenized_attribute(index) unless decl.type.cdata?
      end
      index += 1
    end
    defaults = @dtd.defaulted_attributes(element_id)
    return unless defaults
    defaults.each do |defaulted|
      charge(1)
      next if find_attribute_slot(defaulted.name_id)
      if @attrs.size >= @options.max_attributes
        limit_error("Element has more than max_attributes (#{@options.max_attributes}) attributes")
      end
      charge_default_attribute(defaulted.default_value.size)
      start = @scratch_size
      append_scratch_bytes(defaulted.default_value)
      @attrs << AttributeSlot.new(defaulted.name_id, start, defaulted.default_value.size, true, NameTable::EMPTY_ID, false)
    end
  end

  # Counts one attribute added from a DTD default against its limits. Its
  # bytes count as input for the work budget, like expanded entity text.
  private def charge_default_attribute(bytes : Int32) : Nil
    @default_attribute_count += 1
    @default_attribute_bytes += bytes
    if @default_attribute_count > @options.max_default_attributes
      limit_error("DTD default attributes exceed max_default_attributes (#{@options.max_default_attributes})")
    end
    if @default_attribute_bytes > @options.max_default_attribute_bytes
      limit_error("DTD default attributes exceed max_default_attribute_bytes (#{@options.max_default_attribute_bytes})")
    end
    @meter.add_units(bytes)
    charge(bytes)
  end

  @default_attribute_count = 0
  @default_attribute_bytes = 0_i64

  # Collapses runs of spaces and trims a tokenized attribute value.
  private def normalize_tokenized_attribute(index : Int32) : Nil
    slot = @attrs[index]
    value = attribute_value_bytes(slot)
    charge(value.size)
    start = @scratch_size
    pending_space = false
    value.each do |byte|
      if byte == 0x20
        pending_space = @scratch_size > start
      else
        append_scratch_byte(0x20_u8) if pending_space
        pending_space = false
        append_scratch_byte(byte)
      end
    end
    @attrs[index] = slot.copy_with(value_start: start, value_size: @scratch_size - start, in_scratch: true)
  end

  # Parses an end tag and checks it against the open element.
  private def parse_end_tag : Nil
    @pos += 2
    start, size = scan_name_span
    skip_spaces
    expect_byte('>', "to close the end tag")
    open_id = @open_names.last? || syntax_error("End tag without a matching start tag")
    expected = @names[open_id].to_slice
    actual = @buffer[@mark + start, size]
    unless expected == actual
      syntax_error("End tag '#{String.new(actual)}' does not match start tag '#{@names[open_id]}'")
    end
    if @open_entity_levels.last != @frames.size
      syntax_error("End tag '#{@names[open_id]}' and its start tag are in different entities")
    end
    @open_names.pop
    @namespace_uri_id = @open_namespace_uris.pop
    @pending_binding_mark = @open_binding_marks.pop
    @open_entity_levels.pop
    @node_type = Type::END_ELEMENT
    @name_id = open_id
    @event_depth = @open_names.size
    @phase = Phase::Epilog if @open_names.empty?
  end

  # Scans character data up to the next markup. Returns false when no event
  # was produced (an entity reference started a new source first).
  private def scan_text : Bool
    start = @pos - @mark
    segment = start
    in_scratch = false
    loop do
      # Hot loop: `Slice#index` walks a bounds-checked window of at most
      # SCAN_CHUNK bytes.
      pos = @pos
      limit = @limit
      stop = limit - pos > SCAN_CHUNK ? pos + SCAN_CHUNK : limit
      found = @buffer[pos, stop - pos].index { |byte| CharClass.flags(byte) & CharClass::TEXT_STOP != 0 }
      pos = found ? pos + found : stop
      @pos = pos
      if pos >= stop
        if pos < limit
          scan_checkpoint
          next
        end
        break unless fill
        next
      end
      byte = @buffer[pos]
      case byte
      when '<'.ord
        break
      when 0x0A
        @pos += 1
        newline
      when '&'.ord
        in_scratch = true
        append_input_to_scratch(segment, @pos - @mark - segment)
        action = parse_content_reference
        segment = @pos - @mark
        next if action == REFERENCE_INLINED
        if @scratch_size == 0
          # Nothing to emit yet: start the entity (or report the skipped
          # one) right away.
          if action == REFERENCE_PUSH
            entity = @pending_entity || raise Error.new("BUG: missing pending entity")
            @pending_entity = nil
            push_entity(entity)
            return false
          else
            emit_skipped_entity(@pending_skipped_entity_id)
            @pending_skipped_entity_id = -1
            return true
          end
        end
        break
      when 0x0D
        @pos += 1
        if @in_document_source
          in_scratch = true
          append_input_to_scratch(segment, @pos - 1 - @mark - segment)
          append_scratch_byte(0x0A_u8)
          consume_line_end_after_cr
          newline
          segment = @pos - @mark
        end
      when ']'.ord
        if peek_byte_at(1) == ']'.ord && peek_byte_at(2) == '>'.ord
          syntax_error("']]>' is not allowed in content")
        end
        @pos += 1
      else
        if byte < 0x80
          accept_ascii_control(byte)
          next
        end
        if xml11_line_ends? && (length = xml11_line_end_length) > 0
          in_scratch = true
          append_input_to_scratch(segment, @pos - @mark - segment)
          append_scratch_byte(0x0A_u8)
          @pos += length
          newline
          segment = @pos - @mark
          next
        end
        _, length = decode_at_pos
        @pos += length
      end
    end
    if in_scratch
      append_input_to_scratch(segment, @pos - @mark - segment)
      return false if @scratch_size == 0
      check_token_size(@scratch_size)
      set_value(0, @scratch_size, true)
    else
      size = @pos - @mark - start
      return false if size == 0
      check_token_size(size)
      set_value(start, size, false)
    end
    @event_depth = @open_names.size
    @node_type = whitespace_value? ? Type::SIGNIFICANT_WHITESPACE : Type::TEXT
    true
  end

  @[AlwaysInline]
  private def set_value(start : Int32, size : Int32, in_scratch : Bool) : Nil
    @value_start = start
    @value_size = size
    @value_in_scratch = in_scratch
  end

  # Returns true when the value is all white space; stops at the first
  # other byte, so it reads each byte at most once.
  private def whitespace_value? : Bool
    bytes = value_bytes
    index = 0
    while index < bytes.size
      unless CharClass.space?(bytes[index])
        charge(index + 1)
        return false
      end
      index += 1
    end
    charge(bytes.size)
    true
  end

  # Emits an ENTITY_REFERENCE event for an entity that was not expanded
  # (an external parsed entity, which is never fetched, or an undeclared
  # entity in a document whose declarations were not all read).
  private def emit_skipped_entity(name_id : Int32) : Nil
    @node_type = Type::ENTITY_REFERENCE
    @name_id = name_id
    @namespace_uri_id = NameTable::EMPTY_ID
    @event_depth = @open_names.size
    @value_size = 0
  end

  # Parses `<!-- ... -->`.
  private def parse_comment : Nil
    @pos += 4
    start, size, in_scratch = scan_markup_body('-'.ord.to_u8, "comment")
    set_value(start, size, in_scratch)
    @node_type = Type::COMMENT
    @event_depth = @open_names.size
  end

  # Parses `<![CDATA[ ... ]]>`.
  private def parse_cdata : Nil
    @pos += 9
    start, size, in_scratch = scan_markup_body(']'.ord.to_u8, "CDATA section")
    set_value(start, size, in_scratch)
    @node_type = Type::CDATA
    @event_depth = @open_names.size
  end

  # Parses `<?target data?>`.
  private def parse_processing_instruction : Nil
    target_id = scan_processing_instruction_target
    if peek_byte == '?'.ord && peek_byte_at(1) == '>'.ord
      @pos += 2
      set_value(0, 0, false)
    else
      require_spaces("after the processing instruction target")
      start, size, in_scratch = scan_markup_body('?'.ord.to_u8, "processing instruction")
      set_value(start, size, in_scratch)
    end
    @node_type = Type::PROCESSING_INSTRUCTION
    @name_id = target_id
    @event_depth = @open_names.size
  end

  private def scan_processing_instruction_target : Int32
    @pos += 2
    target_id = scan_name_id
    target = @names[target_id]
    if target.bytesize == 3 && target.compare("xml", case_insensitive: true) == 0
      syntax_error("The processing instruction target '#{target}' is reserved")
    end
    if @options.namespace_aware? && target.includes?(':')
      syntax_error("Processing instruction target '#{target}' must not contain a colon")
    end
    target_id
  end

  # Scans the body of a comment (terminator '-'), CDATA section (']') or
  # PI ('?') and consumes the closing delimiter. Returns
  # `{start, size, in_scratch}`.
  private def scan_markup_body(terminator : UInt8, what : String) : {Int32, Int32, Bool}
    start = @pos - @mark
    segment = start
    in_scratch = false
    scratch_start = @scratch_size
    end_offset = 0
    loop do
      # Hot loop: `Slice#index` walks a bounds-checked window of at most
      # SCAN_CHUNK bytes.
      pos = @pos
      limit = @limit
      stop = limit - pos > SCAN_CHUNK ? pos + SCAN_CHUNK : limit
      found = @buffer[pos, stop - pos].index { |byte| CharClass.flags(byte) & CharClass::CONTENT_STOP != 0 }
      pos = found ? pos + found : stop
      @pos = pos
      if pos >= stop
        if pos < limit
          scan_checkpoint
          next
        end
        syntax_error("Unterminated #{what}") unless fill
        next
      end
      byte = @buffer[pos]
      if byte == terminator
        case terminator
        when '-'.ord
          if peek_byte_at(1) == '-'.ord
            unless peek_byte_at(2) == '>'.ord
              syntax_error("'--' is not allowed inside a comment")
            end
            end_offset = @pos - @mark
            @pos += 3
            break
          end
        when '?'.ord
          if peek_byte_at(1) == '>'.ord
            end_offset = @pos - @mark
            @pos += 2
            break
          end
        else
          if peek_byte_at(1) == ']'.ord && peek_byte_at(2) == '>'.ord
            end_offset = @pos - @mark
            @pos += 3
            break
          end
        end
        @pos += 1
        next
      end
      case byte
      when '-'.ord, '?'.ord, ']'.ord
        @pos += 1
      when 0x0A
        @pos += 1
        newline
      when 0x0D
        @pos += 1
        if @in_document_source
          in_scratch = true
          append_input_to_scratch(segment, @pos - 1 - @mark - segment)
          append_scratch_byte(0x0A_u8)
          consume_line_end_after_cr
          newline
          segment = @pos - @mark
        end
      else
        if byte < 0x80
          accept_ascii_control(byte)
          next
        end
        if xml11_line_ends? && (length = xml11_line_end_length) > 0
          in_scratch = true
          append_input_to_scratch(segment, @pos - @mark - segment)
          append_scratch_byte(0x0A_u8)
          @pos += length
          newline
          segment = @pos - @mark
          next
        end
        _, length = decode_at_pos
        @pos += length
      end
    end
    if in_scratch
      append_input_to_scratch(segment, end_offset - segment)
      size = @scratch_size - scratch_start
      check_token_size(size)
      {scratch_start, size, true}
    else
      check_token_size(end_offset - start)
      {start, end_offset - start, false}
    end
  end
end
