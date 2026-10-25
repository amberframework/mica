module Mica::XML::XPath
  # :nodoc:
  enum TokenKind
    LeftParen
    RightParen
    LeftBracket
    RightBracket
    Dot
    DotDot
    At
    Comma
    ColonColon
    NameTest
    NodeType
    Operator
    FunctionName
    AxisName
    Literal
    Number
    Variable
    End
  end

  # :nodoc:
  #
  # *offset* is the token's byte offset in the expression.
  record Token, kind : TokenKind, text : String, number : Float64 = 0.0, offset : Int32 = 0

  # :nodoc:
  #
  # Splits an XPath 1.0 expression into tokens, applying the lexical
  # disambiguation rules of XPath 1.0 section 3.7.
  class Lexer
    NODE_TYPES     = {"comment", "text", "processing-instruction", "node"}
    OPERATOR_NAMES = {"and", "or", "mod", "div"}

    @tokens = [] of Token

    # Characters the lexer has stepped over (lookahead included), and how
    # many of them were charged. A long literal, name or space run is
    # charged every LEX_CHUNK characters, so it stops partway when the
    # meter runs out.
    @steps = 0
    @charged_steps = 0
    @token_start = 0

    private LEX_CHUNK = 4096

    def initialize(@source : String, @meter : Core::WorkMeter? = nil)
      @reader = Char::Reader.new(@source)
      check_encoding
    end

    def tokenize : Array(Token)
      loop do
        @token_start = @reader.pos
        skip_spaces
        break unless @reader.has_next?
        start = @reader.pos
        @token_start = start
        @tokens << next_token.copy_with(offset: start)
        # One operation per byte stepped over (spaces included) and per
        # token.
        charge_steps(1)
      end
      charge_steps(0)
      @tokens << Token.new(TokenKind::End, "", offset: @source.bytesize)
      @tokens
    end

    private def current : Char
      @reader.current_char
    end

    private def peek(offset : Int32 = 1) : Char
      position = @reader.pos
      # Decoding the lookahead: at most four bytes per character.
      @steps += 4 * offset
      offset.times { @reader.next_char }
      char = @reader.current_char
      @reader.pos = position
      char
    end

    private def advance : Char
      # Charged by bytes, at the current position, so a long literal of
      # multibyte characters trips where the work is.
      charge_steps(0, @reader.pos) if @steps - @charged_steps >= LEX_CHUNK
      before = @reader.pos
      char = @reader.next_char
      @steps += @reader.pos - before
      check_encoding
      char
    end

    # Rejects the current character when the source is not valid UTF-8
    # there, naming the byte offset.
    private def check_encoding : Nil
      if byte = @reader.error
        raise XPathError.new("Invalid UTF-8 byte 0x#{byte.to_s(16, upcase: true, precision: 2)} at byte #{@reader.pos} in #{XPath.quote(@source)}")
      end
    end

    # Charges copying (or otherwise passing over) *bytes* bytes before it
    # happens.
    private def charge_copy(bytes : Int64) : Nil
      XPath.charge_compile(@meter, bytes, @source, @token_start)
    end

    private def charge_steps(extra : Int32, offset : Int32 = @token_start) : Nil
      XPath.charge_compile(@meter, @steps - @charged_steps + extra, @source, offset)
      @charged_steps = @steps
    end

    private def skip_spaces : Nil
      while @reader.has_next? && {' ', '\t', '\n', '\r'}.includes?(current)
        advance
      end
    end

    # True when the previous token makes `*` a multiplication and a name an
    # operator name.
    private def operator_context? : Bool
      previous = @tokens.last?
      return false unless previous
      case previous.kind
      when .at?, .colon_colon?, .left_paren?, .left_bracket?, .comma?, .operator?
        false
      else
        true
      end
    end

    private def next_token : Token
      char = current
      case char
      when '('
        advance
        Token.new(TokenKind::LeftParen, "(")
      when ')'
        advance
        Token.new(TokenKind::RightParen, ")")
      when '['
        advance
        Token.new(TokenKind::LeftBracket, "[")
      when ']'
        advance
        Token.new(TokenKind::RightBracket, "]")
      when '@'
        advance
        Token.new(TokenKind::At, "@")
      when ','
        advance
        Token.new(TokenKind::Comma, ",")
      when ':'
        if peek == ':'
          advance
          advance
          return Token.new(TokenKind::ColonColon, "::")
        end
        raise XPathError.new("Unexpected ':' in #{XPath.quote(@source)}")
      when '.'
        if peek == '.'
          advance
          advance
          return Token.new(TokenKind::DotDot, "..")
        end
        return lex_number if peek.ascii_number?
        advance
        Token.new(TokenKind::Dot, ".")
      when '"', '\''
        lex_literal(char)
      when '$'
        advance
        Token.new(TokenKind::Variable, lex_qname)
      when '/'
        advance
        if current == '/' && @reader.has_next?
          advance
          return Token.new(TokenKind::Operator, "//")
        end
        Token.new(TokenKind::Operator, "/")
      when '|', '+', '-', '='
        advance
        Token.new(TokenKind::Operator, char.to_s)
      when '!'
        advance
        raise XPathError.new("Expected '=' after '!' in #{XPath.quote(@source)}") unless current == '='
        advance
        Token.new(TokenKind::Operator, "!=")
      when '<', '>'
        advance
        if current == '=' && @reader.has_next?
          advance
          return Token.new(TokenKind::Operator, "#{char}=")
        end
        Token.new(TokenKind::Operator, char.to_s)
      when '*'
        advance
        if operator_context?
          Token.new(TokenKind::Operator, "*")
        else
          Token.new(TokenKind::NameTest, "*")
        end
      else
        if char.ascii_number?
          lex_number
        elsif ncname_start?(char)
          lex_name
        else
          raise XPathError.new("Unexpected character #{char.inspect} in #{XPath.quote(@source)}")
        end
      end
    end

    private def lex_number : Token
      start = @reader.pos
      while @reader.has_next? && (current.ascii_number? || current == '.')
        advance
      end
      # Copying, checking and converting the digits each pass over them:
      # charged before they run.
      charge_copy(4_i64 * (@reader.pos - start))
      text = @source.byte_slice(start, @reader.pos - start)
      raise XPathError.new("Malformed number #{XPath.quote(text)}") if text.count('.') > 1
      Token.new(TokenKind::Number, text, XPath.string_to_number(text))
    end

    private def lex_literal(quote : Char) : Token
      advance
      start = @reader.pos
      while @reader.has_next? && current != quote
        advance
      end
      raise XPathError.new("Unterminated string literal in #{XPath.quote(@source)}") unless @reader.has_next?
      charge_copy(@reader.pos - start)
      text = @source.byte_slice(start, @reader.pos - start)
      advance
      Token.new(TokenKind::Literal, text)
    end

    private def ncname_start?(char : Char) : Bool
      char != ':' && CharClass.name_start_char?(char.ord)
    end

    private def ncname_char?(char : Char) : Bool
      char != ':' && CharClass.name_char?(char.ord)
    end

    private def lex_ncname : String
      start = @reader.pos
      raise XPathError.new("Expected a name in #{XPath.quote(@source)}") unless @reader.has_next? && ncname_start?(current)
      while @reader.has_next? && ncname_char?(current)
        advance
      end
      charge_copy(@reader.pos - start)
      @source.byte_slice(start, @reader.pos - start)
    end

    private def lex_qname : String
      first = lex_ncname
      if @reader.has_next? && current == ':' && peek != ':'
        advance
        local = lex_ncname
        charge_copy(first.bytesize.to_i64 + local.bytesize + 1)
        "#{first}:#{local}"
      else
        first
      end
    end

    private def lex_name : Token
      if operator_context?
        name = lex_ncname
        unless OPERATOR_NAMES.includes?(name)
          raise XPathError.new("Expected an operator, found #{XPath.quote(name)} in #{XPath.quote(@source)}")
        end
        return Token.new(TokenKind::Operator, name)
      end
      first = lex_ncname
      name = first
      if @reader.has_next? && current == ':' && peek != ':'
        advance
        if current == '*'
          advance
          charge_copy(first.bytesize.to_i64 + 2)
          return Token.new(TokenKind::NameTest, "#{first}:*")
        end
        local = lex_ncname
        charge_copy(first.bytesize.to_i64 + local.bytesize + 1)
        name = "#{first}:#{local}"
      end
      position = @reader.pos
      skip_spaces
      following = @reader.has_next? ? current : '\0'
      following_second = @reader.has_next? ? peek : '\0'
      @reader.pos = position
      if following == '('
        return Token.new(TokenKind::NodeType, name) if NODE_TYPES.includes?(name)
        return Token.new(TokenKind::FunctionName, name)
      end
      if following == ':' && following_second == ':'
        return Token.new(TokenKind::AxisName, name)
      end
      Token.new(TokenKind::NameTest, name)
    end
  end
end
