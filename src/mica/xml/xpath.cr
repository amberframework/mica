require "./xpath/lexer"
require "./xpath/ast"
require "./xpath/functions"
require "./xpath/parser"
require "./xpath/evaluator"

module Mica::XML
  # XPath 1.0 over `Mica::XML::Document` trees.
  #
  # Supported: the full XPath 1.0 expression grammar (location paths,
  # abbreviations, predicates, filter expressions, unions, arithmetic,
  # comparisons, variables); the axes `child`, `descendant`,
  # `descendant-or-self`, `self`, `parent`, `ancestor`, `ancestor-or-self`,
  # `following`, `following-sibling`, `preceding`, `preceding-sibling` and
  # `attribute`; all node tests; and the core function library except
  # `id()` and `lang()`. The `namespace` axis, `id()` and `lang()` raise
  # `Mica::XML::XPathError`. See the README for the grammar.
  #
  # ```
  # document = Mica::XML.parse(%(<a><b n="1"/><b n="2"/></a>))
  # expression = Mica::XML::XPath.compile("//b[@n > 1]")
  # expression.evaluate(document.node) # => [#<Mica::XML::Node ELEMENT_NODE name="b">]
  # ```
  module XPath
    # The result of an XPath expression.
    alias Value = NodeSet | String | Float64 | Bool

    # The default work budget for one evaluation: 64 operations per node of
    # the document, plus 1,000,000, and at most 10 seconds. Each axis step
    # with position-free predicates is linear in the document, so ordinary
    # queries use a small fraction of it; nested and positional predicates
    # multiply, and the budget stops them.
    DEFAULT_WORK_BUDGET = Core::WorkBudget.new(
      operations_per_unit: 64,
      base_operations: 1_000_000,
      timeout: 10.seconds,
    )

    # A parsed XPath expression that can be evaluated many times.
    class Expression
      getter source : String

      def initialize(@source : String, @root : Expr)
      end

      # Evaluates the expression with *node* as the context node.
      #
      # *namespaces* maps prefixes to URIs; when nil the namespaces declared
      # on the document's root element are used (the default namespace is
      # registered as `xmlns`). The evaluation runs under *budget* (its
      # units are the document's nodes plus the expression's bytes), or
      # draws on *meter* when given. Raises `Mica::WorkBudgetExceededError`
      # or `Mica::DeadlineExceededError`, positioned in the expression, when
      # it runs out.
      def evaluate(node : Node, namespaces : Hash(String, String)? = nil, variables : Hash(String, Value)? = nil,
                   *, budget : Core::WorkBudget = DEFAULT_WORK_BUDGET, meter : Core::WorkMeter? = nil) : Value
        work_meter = meter || Core::WorkMeter.new(budget)
        work_meter.add_units(node.document.node_count.to_i64 + @source.bytesize)
        Evaluator.new(node.document, namespaces || XPath.root_namespaces(node), variables, work_meter, @source).run(@root, node.index)
      end
    end

    # Parses *path*. Raises `Mica::XML::XPathError` on a syntax error or an
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
    #
    # XPath `number()` on a string: optional white space, an optional `-`,
    # then `Digits ('.' Digits?)? | '.' Digits`, then optional white space;
    # anything else is NaN.
    def self.string_to_number(text : String) : Float64
      bytes = text.to_slice
      first = 0
      last = bytes.size
      while first < last && xpath_space?(bytes[first])
        first += 1
      end
      while last > first && xpath_space?(bytes[last - 1])
        last -= 1
      end
      index = first
      index += 1 if index < last && bytes[index] == '-'.ord
      integer_end = skip_digits(bytes, index, last)
      integer_digits = integer_end - index
      index = integer_end
      fraction_digits = 0
      if index < last && bytes[index] == '.'.ord
        fraction_end = skip_digits(bytes, index + 1, last)
        fraction_digits = fraction_end - index - 1
        index = fraction_end
      end
      return Float64::NAN if index != last || (integer_digits == 0 && fraction_digits == 0)
      text.byte_slice(first, last - first).to_f64
    end

    # :nodoc:
    #
    # XPath `normalize-space()`: strips leading and trailing white space and
    # collapses each inner run to one space.
    def self.normalize_space(text : String) : String
      String.build(text.bytesize) do |io|
        pending_space = false
        wrote = false
        text.each_byte do |byte|
          if xpath_space?(byte)
            pending_space = wrote
          else
            io.write_byte(0x20_u8) if pending_space
            pending_space = false
            wrote = true
            io.write_byte(byte)
          end
        end
      end
    end

    private def self.xpath_space?(byte : UInt8) : Bool
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    end

    # Returns the index of the first non-digit in `bytes[from, last - from]`.
    private def self.skip_digits(bytes : Bytes, from : Int32, last : Int32) : Int32
      index = from
      while index < last && bytes[index] >= '0'.ord && bytes[index] <= '9'.ord
        index += 1
      end
      index
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
