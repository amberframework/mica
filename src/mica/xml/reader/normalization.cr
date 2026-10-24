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
  # to be NFC) fail. The bytes are split into segments of one
  # non-composing character and the composing characters after it; the
  # first segment that is not NFC on its own holds the failure. Within it
  # the blamed character is the first whose prefix of the segment is not
  # NFC: the leading character alone, or the composing character that
  # first breaks canonical order or composes. At most
  # MAX_BLAMED_NON_STARTERS + 1 prefixes of at most that many characters
  # are checked, so the search stays linear in the size.
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
  # it, or composes with the leading character without being blocked. The
  # prefix is canonically ordered so far, so *mark* is blocked exactly when
  # a class-0 character came before it or the character before it has the
  # same class. Each test normalizes at most three characters.
  private def blamed_in_segment(bytes : Bytes, start : Int32, first_composing : Int32, stop : Int32) : Int32
    starter = String.new(bytes[start, first_composing - start])
    return start unless starter.unicode_normalized?(:nfc)
    previous = nil
    class_zero_seen = false
    index = first_composing
    while index < stop
      _, length = Core::UTF8.decode(bytes, index, stop)
      length = Math.max(length, 1)
      mark = String.new(bytes[index, length])
      return index unless mark.unicode_normalized?(:nfc)
      blocked = class_zero_seen
      if previous
        return index if reordered?(previous, mark)
        blocked ||= same_combining_class?(previous, mark)
      end
      return index if !blocked && !(starter + mark).unicode_normalized?(:nfc)
      class_zero_seen ||= !nonzero_combining_class?(mark)
      previous = mark
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
