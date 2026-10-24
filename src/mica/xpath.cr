require "./xpath/lexer"
require "./xpath/ast"
require "./xpath/functions"
require "./xpath/parser"
require "./xpath/evaluator"

module Mica
  # XPath 1.0 over `Mica::Document` trees.
  #
  # Supported: the full XPath 1.0 expression grammar (location paths,
  # abbreviations, predicates, filter expressions, unions, arithmetic,
  # comparisons, variables); the axes `child`, `descendant`,
  # `descendant-or-self`, `self`, `parent`, `ancestor`, `ancestor-or-self`,
  # `following`, `following-sibling`, `preceding`, `preceding-sibling` and
  # `attribute`; all node tests; and the core function library except
  # `id()` and `lang()`. The `namespace` axis, `id()` and `lang()` raise
  # `Mica::XPathError`. See the README for the grammar.
  #
  # ```
  # document = Mica.parse(%(<a><b n="1"/><b n="2"/></a>))
  # expression = Mica::XPath.compile("//b[@n > 1]")
  # expression.evaluate(document.node) # => [#<Mica::Node ELEMENT_NODE name="b">]
  # ```
  module XPath
    # The result of an XPath expression.
    alias Value = NodeSet | String | Float64 | Bool

    # A parsed XPath expression that can be evaluated many times.
    class Expression
      getter source : String

      def initialize(@source : String, @root : Expr)
      end

      # Evaluates the expression with *node* as the context node.
      #
      # *namespaces* maps prefixes to URIs; when nil the namespaces declared
      # on the document's root element are used (the default namespace is
      # registered as `xmlns`).
      def evaluate(node : Node, namespaces : Hash(String, String)? = nil, variables : Hash(String, Value)? = nil) : Value
        Evaluator.new(node.document, namespaces || XPath.root_namespaces(node), variables).run(@root, node.index)
      end
    end

    # Parses *path*. Raises `Mica::XPathError` on a syntax error or an
    # unsupported feature.
    def self.compile(path : String) : Expression
      Expression.new(path, Parser.new(path).parse)
    end

    # :nodoc:
    def self.root_namespaces(node : Node) : Hash(String, String)
      namespaces = {} of String => String
      if root = node.root
        root.namespace_definitions.each do |definition|
          href = definition.href
          next unless href
          namespaces[definition.prefix || "xmlns"] = href
        end
      end
      namespaces
    end

    # Converts *value* with the XPath `string()` rules.
    def self.to_xpath_string(value : Value) : String
      case value
      when String
        value
      when Float64
        number_to_string(value)
      when Bool
        value ? "true" : "false"
      else
        node = value.first?
        node ? node.xpath_string_value : ""
      end
    end

    # Converts *value* with the XPath `number()` rules.
    def self.to_xpath_number(value : Value) : Float64
      case value
      when Float64
        value
      when Bool
        value ? 1.0 : 0.0
      else
        string_to_number(to_xpath_string(value))
      end
    end

    # Converts *value* with the XPath `boolean()` rules.
    def self.to_xpath_boolean(value : Value) : Bool
      case value
      when Bool
        value
      when Float64
        !(value == 0 || value.nan?)
      when String
        !value.empty?
      else
        !value.empty?
      end
    end

    # :nodoc:
    def self.string_to_number(text : String) : Float64
      trimmed = text.strip(" \t\r\n")
      return Float64::NAN unless trimmed.matches?(/\A-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z/)
      trimmed.to_f64
    end

    # :nodoc:
    #
    # Formats a number the XPath way: no exponent, no trailing `.0`.
    def self.number_to_string(number : Float64) : String
      return "NaN" if number.nan?
      return (number > 0 ? "Infinity" : "-Infinity") if number.infinite?
      return "0" if number == 0
      if number == number.trunc && number.abs < 1e18
        return number.to_i64.to_s
      end
      text = number.to_s
      return text unless text.includes?('e')
      expand_exponent(text)
    end

    private def self.expand_exponent(text : String) : String
      mantissa, exponent_text = text.split('e')
      negative = mantissa.starts_with?('-')
      mantissa = mantissa.lchop('-')
      integer_part, _, fraction_part = mantissa.partition('.')
      digits = integer_part + fraction_part
      point = integer_part.size + exponent_text.to_i
      body = if point <= 0
               "0." + "0" * -point + digits
             elsif point >= digits.size
               digits + "0" * (point - digits.size)
             else
               digits[0, point] + "." + digits[point..]
             end
      body = body.rstrip('0').rstrip('.') if body.includes?('.')
      negative ? "-#{body}" : body
    end

    # :nodoc:
    #
    # XPath round(): nearest integer, halves toward positive infinity.
    def self.round(number : Float64) : Float64
      return number if number.nan? || number.infinite?
      return -0.0 if number < 0 && number >= -0.5
      (number + 0.5).floor
    end
  end
end
