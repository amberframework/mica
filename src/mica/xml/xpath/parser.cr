module Mica::XML::XPath
  # :nodoc:
  #
  # Recursive-descent parser for the XPath 1.0 expression grammar.
  class Parser
    # Bounds recursion through nested parentheses and predicates.
    MAX_NESTING = 128

    AXES = {
      "ancestor"           => Axis::Ancestor,
      "ancestor-or-self"   => Axis::AncestorOrSelf,
      "attribute"          => Axis::Attribute,
      "child"              => Axis::Child,
      "descendant"         => Axis::Descendant,
      "descendant-or-self" => Axis::DescendantOrSelf,
      "following"          => Axis::Following,
      "following-sibling"  => Axis::FollowingSibling,
      "parent"             => Axis::Parent,
      "preceding"          => Axis::Preceding,
      "preceding-sibling"  => Axis::PrecedingSibling,
      "self"               => Axis::Self,
    }

    @position = 0
    @nesting = 0

    def initialize(@source : String, @meter : Core::WorkMeter? = nil)
      @tokens = Lexer.new(@source, @meter).tokenize
    end

    # Bounds the expression tree height: long operator chains such as
    # `1+1+...+1` are parsed iteratively but evaluated recursively.
    MAX_DEPTH = 256

    def parse : Expr
      expression = parse_or
      unless current.kind.end?
        fail("Unexpected #{XPath.quote(current.text)}")
      end
      fail("Expression nested too deeply (tree height #{expression.depth})") if expression.depth > MAX_DEPTH
      expression
    end

    private def current : Token
      @tokens[@position]
    end

    private def advance : Token
      token = @tokens[@position]
      XPath.charge_compile(@meter, 1, @source, token.offset)
      @position += 1 unless token.kind.end?
      token
    end

    private def operator?(text : String) : Bool
      current.kind.operator? && current.text == text
    end

    private def expect(kind : TokenKind, what : String) : Token
      fail("Expected #{what}") unless current.kind == kind
      advance
    end

    # Sets *expression*'s source offset and returns it.
    private def at(offset : Int32, expression : T) : T forall T
      expression.offset = offset
      expression
    end

    private def fail(message : String) : NoReturn
      raise XPathError.new("#{message} in XPath #{XPath.quote(@source)}")
    end

    private def nested(&)
      @nesting += 1
      fail("Expression nested too deeply") if @nesting > MAX_NESTING
      result = yield
      @nesting -= 1
      result
    end

    private def parse_or : Expr
      left = parse_and
      while operator?("or")
        advance
        left = at(left.offset, BinaryExpr.new("or", left, parse_and))
      end
      left
    end

    private def parse_and : Expr
      left = parse_equality
      while operator?("and")
        advance
        left = at(left.offset, BinaryExpr.new("and", left, parse_equality))
      end
      left
    end

    private def parse_equality : Expr
      left = parse_relational
      while operator?("=") || operator?("!=")
        operator = advance.text
        left = at(left.offset, BinaryExpr.new(operator, left, parse_relational))
      end
      left
    end

    private def parse_relational : Expr
      left = parse_additive
      while operator?("<") || operator?("<=") || operator?(">") || operator?(">=")
        operator = advance.text
        left = at(left.offset, BinaryExpr.new(operator, left, parse_additive))
      end
      left
    end

    private def parse_additive : Expr
      left = parse_multiplicative
      while operator?("+") || operator?("-")
        operator = advance.text
        left = at(left.offset, BinaryExpr.new(operator, left, parse_multiplicative))
      end
      left
    end

    private def parse_multiplicative : Expr
      left = parse_unary
      while operator?("*") || operator?("div") || operator?("mod")
        operator = advance.text
        left = at(left.offset, BinaryExpr.new(operator, left, parse_unary))
      end
      left
    end

    private def parse_unary : Expr
      if operator?("-")
        offset = advance.offset
        return nested { at(offset, NegateExpr.new(parse_unary)) }
      end
      parse_union
    end

    private def parse_union : Expr
      left = parse_path
      while operator?("|")
        advance
        left = at(left.offset, BinaryExpr.new("|", left, parse_path))
      end
      left
    end

    private def location_path_start? : Bool
      case current.kind
      when .dot?, .dot_dot?, .at?, .axis_name?, .name_test?, .node_type?
        true
      when .operator?
        current.text == "/" || current.text == "//"
      else
        false
      end
    end

    private def parse_path : Expr
      return parse_location_path if location_path_start?
      offset = current.offset
      filter = parse_filter
      steps = [] of Step
      if operator?("/") || operator?("//")
        parse_relative_steps(steps)
        return at(offset, PathExpr.new(filter, false, steps))
      end
      filter
    end

    private def parse_filter : Expr
      offset = current.offset
      primary = parse_primary
      predicates = parse_predicates
      predicates.empty? ? primary : at(offset, FilterExpr.new(primary, predicates))
    end

    private def parse_primary : Expr
      token = current
      expression = case token.kind
                   when .variable?
                     advance
                     VariableExpr.new(token.text)
                   when .left_paren?
                     advance
                     inner = nested { parse_or }
                     expect(TokenKind::RightParen, "')'")
                     return inner
                   when .literal?
                     advance
                     LiteralExpr.new(token.text)
                   when .number?
                     advance
                     NumberExpr.new(token.number)
                   when .function_name?
                     advance
                     parse_function_call(token.text)
                   else
                     fail("Unexpected #{XPath.quote(token.text)}")
                   end
      at(token.offset, expression)
    end

    private def parse_function_call(name : String) : Expr
      expect(TokenKind::LeftParen, "'('")
      arguments = [] of Expr
      unless current.kind.right_paren?
        arguments << nested { parse_or }
        while current.kind.comma?
          advance
          arguments << nested { parse_or }
        end
      end
      expect(TokenKind::RightParen, "')'")
      Functions.check_signature(name, arguments.size, @source)
      FunctionCall.new(name, arguments)
    end

    private def parse_location_path : Expr
      offset = current.offset
      steps = [] of Step
      absolute = false
      if operator?("/")
        advance
        absolute = true
        # A lone "/" selects the document node.
        return at(offset, PathExpr.new(nil, true, steps)) unless step_start?
        steps << parse_step
      elsif operator?("//")
        separator = advance
        absolute = true
        steps << descendant_or_self_step(separator.offset)
        steps << parse_step
      else
        steps << parse_step
      end
      parse_relative_steps(steps)
      at(offset, PathExpr.new(nil, absolute, steps))
    end

    private def step_start? : Bool
      case current.kind
      when .dot?, .dot_dot?, .at?, .axis_name?, .name_test?, .node_type?
        true
      else
        false
      end
    end

    private def parse_relative_steps(steps : Array(Step)) : Nil
      while operator?("/") || operator?("//")
        separator = advance
        if separator.text == "//"
          steps << descendant_or_self_step(separator.offset)
        end
        steps << parse_step
      end
    end

    private def descendant_or_self_step(offset : Int32 = current.offset) : Step
      Step.new(Axis::DescendantOrSelf, NodeTest.new(TestKind::AnyNode), [] of Expr, offset)
    end

    private def parse_step : Step
      offset = current.offset
      if current.kind.dot?
        advance
        return Step.new(Axis::Self, NodeTest.new(TestKind::AnyNode), [] of Expr, offset)
      end
      if current.kind.dot_dot?
        advance
        return Step.new(Axis::Parent, NodeTest.new(TestKind::AnyNode), [] of Expr, offset)
      end
      axis = Axis::Child
      if current.kind.at?
        advance
        axis = Axis::Attribute
      elsif current.kind.axis_name?
        name = advance.text
        if name == "namespace"
          fail("The namespace axis is not supported")
        end
        axis = AXES[name]? || fail("Unknown axis #{XPath.quote(name)}")
        expect(TokenKind::ColonColon, "'::'")
      end
      test = parse_node_test
      Step.new(axis, test, parse_predicates, offset)
    end

    private def parse_node_test : NodeTest
      token = current
      case token.kind
      when .name_test?
        advance
        text = token.text
        return NodeTest.new(TestKind::AnyName) if text == "*"
        if text.ends_with?(":*")
          return NodeTest.new(TestKind::NamespaceAny, text[0, text.size - 2])
        end
        if colon = text.index(':')
          return NodeTest.new(TestKind::Name, text[0, colon], text[colon + 1..])
        end
        NodeTest.new(TestKind::Name, nil, text)
      when .node_type?
        advance
        expect(TokenKind::LeftParen, "'('")
        test = case token.text
               when "node"    then NodeTest.new(TestKind::AnyNode)
               when "text"    then NodeTest.new(TestKind::Text)
               when "comment" then NodeTest.new(TestKind::Comment)
               else
                 target = nil
                 if current.kind.literal?
                   target = advance.text
                 end
                 NodeTest.new(TestKind::PI, nil, target)
               end
        expect(TokenKind::RightParen, "')'")
        test
      else
        fail("Expected a node test, found #{XPath.quote(token.text)}")
      end
    end

    private def parse_predicates : Array(Expr)
      predicates = [] of Expr
      while current.kind.left_bracket?
        advance
        predicates << nested { parse_or }
        expect(TokenKind::RightBracket, "']'")
      end
      predicates
    end
  end
end
