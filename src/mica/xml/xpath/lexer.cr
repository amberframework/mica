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

    def initialize(@source : String)
      @reader = Char::Reader.new(@source)
    end

    def tokenize : Array(Token)
      loop do
        skip_spaces
        break unless @reader.has_next?
        start = @reader.pos
        @tokens << next_token.copy_with(offset: start)
      end
      @tokens << Token.new(TokenKind::End, "", offset: @source.bytesize)
      @tokens
    end

    private def current : Char
      @reader.current_char
    end

    private def peek(offset : Int32 = 1) : Char
      position = @reader.pos
      offset.times { @reader.next_char }
      char = @reader.current_char
      @reader.pos = position
      char
    end

    private def advance : Char
      @reader.next_char
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
        raise XPathError.new("Unexpected ':' in #{@source.inspect}")
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
        raise XPathError.new("Expected '=' after '!' in #{@source.inspect}") unless current == '='
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
          raise XPathError.new("Unexpected character #{char.inspect} in #{@source.inspect}")
        end
      end
    end

    private def lex_number : Token
      start = @reader.pos
      while @reader.has_next? && (current.ascii_number? || current == '.')
        advance
      end
      text = @source.byte_slice(start, @reader.pos - start)
      raise XPathError.new("Malformed number #{text.inspect}") if text.count('.') > 1
      Token.new(TokenKind::Number, text, XPath.string_to_number(text))
    end

    private def lex_literal(quote : Char) : Token
      advance
      start = @reader.pos
      while @reader.has_next? && current != quote
        advance
      end
      raise XPathError.new("Unterminated string literal in #{@source.inspect}") unless @reader.has_next?
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
      raise XPathError.new("Expected a name in #{@source.inspect}") unless @reader.has_next? && ncname_start?(current)
      while @reader.has_next? && ncname_char?(current)
        advance
      end
      @source.byte_slice(start, @reader.pos - start)
    end

    private def lex_qname : String
      first = lex_ncname
      if @reader.has_next? && current == ':' && peek != ':'
        advance
        "#{first}:#{lex_ncname}"
      else
        first
      end
    end

    private def lex_name : Token
      if operator_context?
        name = lex_ncname
        unless OPERATOR_NAMES.includes?(name)
          raise XPathError.new("Expected an operator, found #{name.inspect} in #{@source.inspect}")
        end
        return Token.new(TokenKind::Operator, name)
      end
      first = lex_ncname
      name = first
      if @reader.has_next? && current == ':' && peek != ':'
        advance
        if current == '*'
          advance
          return Token.new(TokenKind::NameTest, "#{first}:*")
        end
        name = "#{first}:#{lex_ncname}"
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
