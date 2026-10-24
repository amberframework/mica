class Mica::XML::Reader
  # Checks the encoding signature and reads the XML declaration.
  private def start_document : Nil
    @phase = Phase::Prolog
    # The meter may have started long before the first read (and the
    # signature read may have waited on the IO).
    @meter.enforce_deadline { error_position }
    if problem = @encoding_problem
      encoding_error(problem)
    end
    check_input_size
    @mark = @pos
    if starts_with?("<?xml") && CharClass.space?(peek_byte_at(5).to_u8!)
      parse_xml_declaration
    end
  end

  # Parses `<?xml version="1.x" encoding="..." standalone="..."?>`. XML 1.1
  # rules start after the declaration (NEL and LSEP inside it are errors).
  private def parse_xml_declaration : Nil
    @pos += 5
    skip_spaces
    expect_literal("version", "in the XML declaration")
    @xml_version = parse_declaration_value("version")
    unless version_number?(@xml_version)
      syntax_error("Unsupported XML version '#{@xml_version}'")
    end
    had_space = skip_spaces
    declared_encoding = nil
    if starts_with?("encoding")
      syntax_error("Expected white space before 'encoding'") unless had_space
      @pos += 8
      declared = parse_declaration_value("encoding")
      syntax_error("Invalid encoding name '#{declared}'") unless encoding_name?(declared)
      declared_encoding = declared
      had_space = skip_spaces
    end
    if starts_with?("standalone")
      syntax_error("Expected white space before 'standalone'") unless had_space
      @pos += 10
      case parse_declaration_value("standalone")
      when "yes"
        @standalone = true
      when "no"
        @standalone = false
      else
        syntax_error("standalone must be 'yes' or 'no'")
      end
      skip_spaces
    end
    expect_literal("?>", "to close the XML declaration")
    @xml11 = @xml_version == "1.1"
    charge(@pos - @mark + TOKEN_OPERATIONS)
    @mark = @pos
    apply_declared_encoding(declared_encoding) if declared_encoding
  end

  # VersionNum ::= '1.' [0-9]+
  private def version_number?(text : String) : Bool
    bytes = text.to_slice
    return false unless bytes.size > 2 && bytes[0] == '1'.ord && bytes[1] == '.'.ord
    bytes[2, bytes.size - 2].all? { |byte| byte >= '0'.ord && byte <= '9'.ord }
  end

  # EncName ::= [A-Za-z] ([A-Za-z0-9._] | '-')*
  private def encoding_name?(text : String) : Bool
    bytes = text.to_slice
    return false if bytes.empty?
    first = bytes[0]
    return false unless (first >= 'A'.ord && first <= 'Z'.ord) || (first >= 'a'.ord && first <= 'z'.ord)
    bytes.all? do |byte|
      (byte >= 'A'.ord && byte <= 'Z'.ord) || (byte >= 'a'.ord && byte <= 'z'.ord) ||
        (byte >= '0'.ord && byte <= '9'.ord) || byte == '.'.ord || byte == '_'.ord || byte == '-'.ord
    end
  end

  # Parses `S? '=' S? ("value" | 'value')` inside the XML declaration.
  private def parse_declaration_value(what : String) : String
    skip_spaces
    expect_byte('=', "after '#{what}'")
    skip_spaces
    quote = peek_byte
    unless quote == '"'.ord || quote == '\''.ord
      syntax_error("Expected a quoted value for '#{what}'")
    end
    @pos += 1
    start = @pos - @mark
    loop do
      byte = peek_byte
      syntax_error("Unterminated value for '#{what}'") if byte < 0
      break if byte == quote
      syntax_error("Invalid character in '#{what}'") if byte >= 0x80 || byte < 0x20 || byte == '<'.ord
      @pos += 1
      check_token_size(@pos - @mark - start)
    end
    value = String.new(@buffer[@mark + start, @pos - @mark - start])
    @pos += 1
    value
  end

  # Checks the declared encoding against the byte order mark and switches
  # decoding when the document is ISO-8859-1 (XML 1.0 section 4.3.3).
  private def apply_declared_encoding(declared : String) : Nil
    encoding = Core::Encoding.from_label(declared)
    signature = @signature
    case encoding
    when .nil?
      encoding_error("Unsupported encoding '#{declared}'; Mica::XML decodes UTF-8, UTF-16, ISO-8859-1 and US-ASCII")
    when .utf8?
      encoding_error("Document declares #{declared} but is encoded in UTF-16") if signature.utf16?
      @encoding = "UTF-8"
    when .utf16?
      encoding_error("Document declares #{declared} but has no UTF-16 byte order mark") unless signature.utf16?
      if declared_byte_order_conflicts?(declared, signature)
        encoding_error("Document declares #{declared} but its byte order mark says otherwise")
      end
      @encoding = "UTF-16"
    when .usascii?
      encoding_error("Document declares #{declared} but is encoded in UTF-16") if signature.utf16?
      @ascii_only = true
      @encoding = "US-ASCII"
    when .iso8859_1?
      encoding_error("Document declares #{declared} but is encoded in UTF-16") if signature.utf16?
      encoding_error("Document declares #{declared} but begins with a UTF-8 byte order mark") if signature.utf8? && @source_prefix_bytes > 0
      @encoding = "ISO-8859-1"
      switch_to_transcoder(Core::Encoding::ISO8859_1)
    else
      encoding_error("Unsupported encoding '#{declared}'; Mica::XML decodes UTF-8, UTF-16, ISO-8859-1 and US-ASCII")
    end
  end

  # UTF-16LE/UTF-16BE (explicit byte order) must agree with the mark;
  # plain UTF-16 accepts either.
  private def declared_byte_order_conflicts?(declared : String, signature : Core::Encoding) : Bool
    upper = declared.upcase
    return signature.utf16_be? if upper.ends_with?("LE")
    return signature.utf16_le? if upper.ends_with?("BE")
    false
  end

  # Reads one token outside the root element: white space (skipped), a
  # comment, a PI, the DOCTYPE or the root start tag. Returns true when it
  # produced an event.
  private def misc_token : Bool
    return false if skip_spaces
    byte = peek_byte
    return false if byte < 0
    unless byte == '<'.ord
      if @phase.prolog?
        syntax_error("Content is not allowed in the prolog")
      else
        syntax_error("Extra content at the end of the document")
      end
    end
    case peek_byte_at(1)
    when '?'.ord
      parse_processing_instruction
    when '!'.ord
      if starts_with?("<!--")
        parse_comment
      elsif starts_with?("<!DOCTYPE")
        if !@phase.prolog? || @doctype_seen
          syntax_error("A DOCTYPE declaration must come once, before the root element")
        end
        parse_doctype
      else
        syntax_error("Unexpected markup outside the root element")
      end
    else
      if @phase.epilog?
        syntax_error("Extra content at the end of the document: only one root element is allowed")
      end
      @root_seen = true
      @phase = Phase::Content
      parse_start_tag
    end
    true
  end

  # Ends the document: every element must be closed and a root must exist.
  private def finish_document : Nil
    if @phase.content?
      if open_id = @open_names.last?
        syntax_error("Unexpected end of document: element '#{@names[open_id]}' is not closed")
      end
    end
    syntax_error("Document has no root element") unless @root_seen
    @meter.enforce_deadline { error_position }
    @phase = Phase::Done
    @node_type = Type::NONE
    @attrs.clear
    @value_size = 0
  end
end
