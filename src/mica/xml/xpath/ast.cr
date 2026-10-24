module Mica::XML::XPath
  # :nodoc:
  enum Axis
    Ancestor
    AncestorOrSelf
    Attribute
    Child
    Descendant
    DescendantOrSelf
    Following
    FollowingSibling
    Parent
    Preceding
    PrecedingSibling
    Self

    def reverse? : Bool
      ancestor? || ancestor_or_self? || preceding? || preceding_sibling?
    end
  end

  # :nodoc:
  enum TestKind
    Name         # prefix:local, local
    AnyName      # *
    NamespaceAny # prefix:*
    AnyNode      # node()
    Text         # text()
    Comment      # comment()
    PI           # processing-instruction('target'?)
  end

  # :nodoc:
  #
  # Static result type, used to decide whether `//x[pred]` may be rewritten
  # to `descendant::x[pred]`.
  enum StaticType
    NodeSet
    String
    Number
    Boolean
    Unknown
  end

  # :nodoc:
  abstract class Expr
    abstract def static_type : StaticType

    # Height of the expression tree, which bounds evaluation recursion.
    getter depth : Int32 = 1

    # Byte offset of the expression's first token in the XPath source.
    property offset : Int32 = 0

    protected def self.max_depth(list_of_expressions : Enumerable(Expr)) : Int32
      list_of_expressions.max_of?(&.depth) || 0
    end

    # True when the expression calls position() or last() anywhere.
    abstract def uses_context_position? : Bool
  end

  # :nodoc:
  class BinaryExpr < Expr
    getter operator : String
    getter left : Expr
    getter right : Expr

    def initialize(@operator : String, @left : Expr, @right : Expr)
      @depth = Math.max(@left.depth, @right.depth) + 1
    end

    def static_type : StaticType
      case @operator
      when "or", "and", "=", "!=", "<", "<=", ">", ">="
        StaticType::Boolean
      when "|"
        StaticType::NodeSet
      else
        StaticType::Number
      end
    end

    def uses_context_position? : Bool
      @left.uses_context_position? || @right.uses_context_position?
    end
  end

  # :nodoc:
  class NegateExpr < Expr
    getter operand : Expr

    def initialize(@operand : Expr)
      @depth = @operand.depth + 1
    end

    def static_type : StaticType
      StaticType::Number
    end

    def uses_context_position? : Bool
      @operand.uses_context_position?
    end
  end

  # :nodoc:
  class LiteralExpr < Expr
    getter value : String

    def initialize(@value : String)
    end

    def static_type : StaticType
      StaticType::String
    end

    def uses_context_position? : Bool
      false
    end
  end

  # :nodoc:
  class NumberExpr < Expr
    getter value : Float64

    def initialize(@value : Float64)
    end

    def static_type : StaticType
      StaticType::Number
    end

    def uses_context_position? : Bool
      false
    end
  end

  # :nodoc:
  class VariableExpr < Expr
    getter name : String

    def initialize(@name : String)
    end

    def static_type : StaticType
      StaticType::Unknown
    end

    def uses_context_position? : Bool
      false
    end
  end

  # :nodoc:
  class FunctionCall < Expr
    NUMBER_FUNCTIONS  = {"last", "position", "count", "string-length", "number", "sum", "floor", "ceiling", "round"}
    BOOLEAN_FUNCTIONS = {"not", "true", "false", "boolean", "starts-with", "contains"}

    getter name : String
    getter list_of_arguments : Array(Expr)

    def initialize(@name : String, @list_of_arguments : Array(Expr))
      @depth = Expr.max_depth(@list_of_arguments) + 1
    end

    def static_type : StaticType
      return StaticType::Number if NUMBER_FUNCTIONS.includes?(@name)
      return StaticType::Boolean if BOOLEAN_FUNCTIONS.includes?(@name)
      StaticType::String
    end

    def uses_context_position? : Bool
      @name == "position" || @name == "last" || @list_of_arguments.any?(&.uses_context_position?)
    end
  end

  # :nodoc:
  class NodeTest
    getter kind : TestKind
    getter prefix : String?
    getter local : String?

    def initialize(@kind : TestKind, @prefix : String? = nil, @local : String? = nil)
    end
  end

  # :nodoc:
  class Step
    getter axis : Axis
    getter test : NodeTest
    getter list_of_predicates : Array(Expr)
    # Byte offset of the step in the XPath source.
    getter offset : Int32

    def initialize(@axis : Axis, @test : NodeTest, @list_of_predicates : Array(Expr), @offset : Int32 = 0)
    end

    # True for `descendant-or-self::node()` with no predicates (the `//`
    # abbreviation).
    def descendant_or_self_node? : Bool
      @axis.descendant_or_self? && @test.kind.any_node? && @list_of_predicates.empty?
    end

    # True when the predicates do not depend on the proximity position.
    def position_free? : Bool
      @list_of_predicates.all? do |predicate|
        type = predicate.static_type
        !type.number? && !type.unknown? && !predicate.uses_context_position?
      end
    end
  end

  # :nodoc:
  #
  # A location path, optionally starting from a filter expression.
  class PathExpr < Expr
    getter filter : Expr?
    getter? absolute : Bool
    getter list_of_steps : Array(Step)

    def initialize(@filter : Expr?, @absolute : Bool, @list_of_steps : Array(Step))
      deepest = @filter.try(&.depth) || 0
      @list_of_steps.each { |step| deepest = Math.max(deepest, Expr.max_depth(step.list_of_predicates)) }
      @depth = deepest + 1
    end

    def static_type : StaticType
      StaticType::NodeSet
    end

    def uses_context_position? : Bool
      filter = @filter
      return true if filter && filter.uses_context_position?
      @list_of_steps.any? { |step| step.list_of_predicates.any?(&.uses_context_position?) }
    end
  end

  # :nodoc:
  class FilterExpr < Expr
    getter primary : Expr
    getter list_of_predicates : Array(Expr)

    def initialize(@primary : Expr, @list_of_predicates : Array(Expr))
      @depth = Math.max(@primary.depth, Expr.max_depth(@list_of_predicates)) + 1
    end

    def static_type : StaticType
      @primary.static_type
    end

    def uses_context_position? : Bool
      @primary.uses_context_position? || @list_of_predicates.any?(&.uses_context_position?)
    end
  end
end
