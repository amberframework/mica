class Mica::Reader
  # Checks the encoding signature and reads the XML declaration.
  private def start_document : Nil
    @phase = Phase::Prolog
    if problem = @encoding_problem
      encoding_error(problem)
    end
    check_input_size
    @mark = @pos
    if starts_with?("<?xml") && CharClass.space?(peek_byte_at(5).to_u8!)
      parse_xml_declaration
    end
  end

  # Parses `<?xml version="1.x" encoding="..." standalone="..."?>`.
  private def parse_xml_declaration : Nil
    @pos += 5
    skip_spaces
    expect_literal("version", "in the XML declaration")
    @xml_version = parse_declaration_value("version")
    unless @xml_version.matches?(/\A1\.[0-9]+\z/)
      syntax_error("Unsupported XML version '#{@xml_version}'")
    end
    had_space = skip_spaces
    if starts_with?("encoding")
      syntax_error("Expected white space before 'encoding'") unless had_space
      @pos += 8
      declared = parse_declaration_value("encoding")
      unless declared.matches?(/\A[A-Za-z][A-Za-z0-9._\-]*\z/)
        syntax_error("Invalid encoding name '#{declared}'")
      end
      apply_declared_encoding(declared)
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
    end
    value = String.new(@buffer[@mark + start, @pos - @mark - start])
    @pos += 1
    value
  end

  private def apply_declared_encoding(declared : String) : Nil
    normalized = declared.upcase
    utf16_input = @encoding == "UTF-16"
    case normalized
    when "UTF-8", "UTF8"
      encoding_error("Document declares UTF-8 but is encoded in UTF-16") if utf16_input
      @encoding = "UTF-8"
    when "UTF-16", "UTF16", "UTF-16LE", "UTF-16BE"
      encoding_error("Document declares #{declared} but has no UTF-16 byte order mark") unless utf16_input
      @encoding = "UTF-16"
    when "US-ASCII", "ASCII"
      encoding_error("Document declares #{declared} but is encoded in UTF-16") if utf16_input
      @ascii_only = true
      @encoding = "US-ASCII"
    else
      encoding_error("Unsupported encoding '#{declared}'; Mica decodes UTF-8 and UTF-16 only")
    end
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
    @phase = Phase::Done
    @node_type = Type::NONE
    @attrs.clear
    @value_size = 0
  end
end
