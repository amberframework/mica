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
      check_normalized_name(@name_id, 1)
      ordinal = 0
      @attrs.each do |slot|
        check_normalized_name(slot.name_id, attribute_ordinal: slot.specified ? ordinal : nil)
        ordinal += 1 if slot.specified
        check_normalized_attribute_value(slot)
      end
    when .text?, .significant_whitespace?
      check_normalized_value("character content")
    when .cdata?
      check_normalized_value("CDATA section")
    when .comment?
      check_normalized_value("comment")
    when .processing_instruction?
      check_normalized_name(@name_id, 2)
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
  # buffer bytes from *index* to *stop*, with the document's line ends (in
  # XML 1.1 also NEL and LSEP, and CR NEL as one).
  private def position_after(start : Core::Position, index : Int32, stop : Int32) : Core::Position
    line = start.line
    column = start.column
    while index < stop
      length = line_end_length(index, stop)
      if length > 0
        line += 1
        column = 1
        index += length
        next
      end
      column += 1 unless @buffer[index] & 0xC0 == 0x80
      index += 1
    end
    Core::Position.new(source_offset_at(@buffer, stop, @base_offset), line, column)
  end

  # Returns the bytes of the line end at *index* (before *stop*), or 0.
  private def line_end_length(index : Int32, stop : Int32) : Int32
    byte = @buffer[index]
    return 1 if byte == 0x0A
    if byte == 0x0D
      return 2 if index + 1 < stop && @buffer[index + 1] == 0x0A
      return 1 + xml11_line_end_length(index + 1, stop) if @xml11 && index + 1 < stop && @buffer[index + 1] == 0xC2
      return 1
    end
    @xml11 ? xml11_line_end_length(index, stop) : 0
  end

  # Returns the bytes of an XML 1.1 NEL (C2 85) or LSEP (E2 80 A8) at
  # *index*, or 0.
  private def xml11_line_end_length(index : Int32, stop : Int32) : Int32
    rest = @buffer[index, stop - index]
    return 2 if rest.size >= 2 && rest[0] == 0xC2 && rest[1] == 0x85
    return 3 if rest.size >= 3 && rest[0] == 0xE2 && rest[1] == 0x80 && rest[2] == 0xA8
    0
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

  # Checks a name once per document. With *name_offset* (where the name
  # starts in the current token, relative to `@mark`) or *attribute_ordinal*
  # (the attribute's place among the tag's specified attributes, located
  # only when there is an error) the error points at the offending
  # character; otherwise at the token.
  private def check_normalized_name(name_id : Int32, name_offset : Int32? = nil, attribute_ordinal : Int32? = nil) : Nil
    return if @normalized_name_ids.includes?(name_id)
    bytes = @names[name_id].to_slice
    check_normalized(bytes, "name", nil) do |offending|
      start = @token_position
      offset = name_offset || attribute_ordinal.try { |ordinal| attribute_name_offset(ordinal) }
      if start.nil?
        error_position
      elsif offset && @frames.empty?
        position_after(start, @mark, @mark + offset + offending)
      else
        start
      end
    end
    @normalized_name_ids << name_id
  end

  # Returns where the *ordinal*-th attribute name of the current start tag
  # begins, relative to `@mark`, by stepping over the tag's bytes (only on
  # the error path's way to a position, so linear and rare).
  private def attribute_name_offset(ordinal : Int32) : Int32?
    index = @mark + 1 + @names[@name_id].bytesize
    stop = Math.min(@pos, @limit)
    count = 0
    while index < stop
      byte = @buffer[index]
      if (space = white_space_length(index, stop)) > 0
        index += space
        next
      end
      return if byte == '/'.ord || byte == '>'.ord
      return index - @mark if count == ordinal
      index = skip_until(index, stop, '='.ord.to_u8) + 1
      while index < stop && (space = white_space_length(index, stop)) > 0
        index += space
      end
      return if index >= stop
      index = skip_until(index + 1, stop, @buffer[index]) + 1
      count += 1
    end
    nil
  end

  # Returns the bytes of the white space at *index*: a space, tab or line
  # end (in XML 1.1 including NEL and LSEP), or 0.
  private def white_space_length(index : Int32, stop : Int32) : Int32
    byte = @buffer[index]
    return 1 if byte == 0x20 || byte == 0x09
    line_end_length(index, stop)
  end

  # Returns the index of the first *target* byte from *index*, or *stop*.
  private def skip_until(index : Int32, stop : Int32, target : UInt8) : Int32
    while index < stop && @buffer[index] != target
      index += 1
    end
    index
  end

  # Checks an attribute value. When the value lies unchanged in the tag an
  # error points at the offending character; a value that was rewritten
  # (references expanded, white space normalized) no longer matches the
  # source byte for byte, so its error points at the tag.
  private def check_normalized_attribute_value(slot : AttributeSlot) : Nil
    bytes = attribute_value_bytes(slot)
    check_normalized(bytes, "attribute value", nil) do |offending|
      start = @token_position
      if start.nil?
        error_position
      elsif slot.specified && !slot.in_scratch && @frames.empty?
        position_after(start, @mark, @mark + slot.value_start + offending)
      else
        start
      end
    end
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
      raise NormalizationError.new("The #{construct} starts with the composing character U+#{hex_code(code)} (XML 1.1 section 2.13)", yield 0)
    end
    return if String.new(bytes).unicode_normalized?(:nfc)
    raise NormalizationError.new("The #{construct} is not in Unicode Normalization Form C (XML 1.1 section 2.13)", yield offending_normalization_index(bytes))
  end

  # Returns the byte index of the character that makes *bytes* (known not
  # to be NFC) fail. The bytes are split into segments of one
  # non-composing character and the composing characters after it; the
  # first segment that is not NFC on its own holds the failure, and
  # `blamed_in_segment` finds in it the first character whose prefix is
  # not NFC, in one pass with constant work per character.
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
      return blamed_in_segment(bytes, segment_start, first_composing, index)
    end
    0
  end

  # The first character of the non-NFC segment `bytes[start, stop - start]`
  # (composing characters from *first_composing*) whose prefix of the
  # segment is not NFC, found in one pass with constant work per character.
  #
  # The leading character is blamed when it is not NFC alone. Each later
  # character *mark* extends an NFC prefix, which stays NFC unless *mark*
  # is not NFC alone, is out of canonical order after the character before
  # it, or composes with the last starter without being blocked. A
  # composing character of class 0 that does not compose is itself the
  # last starter for what follows. Since the prefix is canonically ordered,
  # *mark* is blocked exactly when a non-starter comes between it and the
  # last starter and *mark* has class 0 or the same class as the character
  # before it. Each test normalizes at most three characters.
  private def blamed_in_segment(bytes : Bytes, start : Int32, first_composing : Int32, stop : Int32) : Int32
    starter = String.new(bytes[start, first_composing - start])
    return start unless starter.unicode_normalized?(:nfc)
    previous = nil
    index = first_composing
    while index < stop
      _, length = Core::UTF8.decode(bytes, index, stop)
      length = Math.max(length, 1)
      mark = String.new(bytes[index, length])
      return index unless mark.unicode_normalized?(:nfc)
      nonzero = nonzero_combining_class?(mark)
      blocked = false
      if previous
        return index if reordered?(previous, mark)
        # A non-starter before *mark* blocks it unless *mark* has a higher
        # class (canonical order already holds, so only equal classes and
        # class 0 remain).
        blocked = !nonzero || same_combining_class?(previous, mark)
      end
      return index if !blocked && !(starter + mark).unicode_normalized?(:nfc)
      if nonzero
        previous = mark
      else
        starter = mark
        previous = nil
      end
      index += length
    end
    first_composing
  end

  # True when canonical ordering moves *second* before *first*.
  private def reordered?(first : String, second : String) : Bool
    (first + second).unicode_normalize(:nfd) != first.unicode_normalize(:nfd) + second.unicode_normalize(:nfd)
  end

  # True when two non-starters have the same canonical combining class:
  # canonical ordering keeps them in place in both orders.
  private def same_combining_class?(first : String, second : String) : Bool
    nonzero_combining_class?(first) && nonzero_combining_class?(second) &&
      !reordered?(first, second) && !reordered?(second, first)
  end

  # U+0345 has class 240 and U+0334 class 1: canonical ordering moves the
  # first after, or the second before, any character of class 2 to 239.
  YPOGEGRAMMENI = "\u{0345}"
  TILDE_OVERLAY = "\u{0334}"

  # True when *mark* (one character) has a non-zero canonical combining
  # class; the class is not public in the standard library, so it is read
  # through canonical ordering against two characters of known class.
  private def nonzero_combining_class?(mark : String) : Bool
    first = mark.unicode_normalize(:nfd)[0].to_s
    return true if first == YPOGEGRAMMENI || first == TILDE_OVERLAY
    return true if (YPOGEGRAMMENI + first).unicode_normalize(:nfd).starts_with?(first)
    (first + TILDE_OVERLAY).unicode_normalize(:nfd).starts_with?(TILDE_OVERLAY)
  end
end
