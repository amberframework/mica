module Mica::XPath
  # :nodoc:
  #
  # Evaluates a parsed expression against one document. Node sets are
  # arrays of arena indices kept in document order.
  class Evaluator
    alias Result = Array(Int32) | String | Float64 | Bool

    # Resolved form of a node test.
    private record Matcher, kind : TestKind, local_id : Int32, uri_id : Int32, target : String?

    @names : NameTable

    def initialize(@document : Document, @namespaces : Hash(String, String), @variables : Hash(String, Value)?)
      @names = @document.names
    end

    def run(expression : Expr, context : Int32) : Value
      to_value(evaluate(expression, context, 1, 1))
    end

    private def to_value(result : Result) : Value
      if result.is_a?(Array(Int32))
        NodeSet.new(result.map { |index| Node.new(@document, index) })
      else
        result
      end
    end

    def evaluate(expression : Expr, node : Int32, position : Int32, size : Int32) : Result
      if expression.is_a?(PathExpr)
        evaluate_path(expression, node, position, size)
      elsif expression.is_a?(BinaryExpr)
        evaluate_binary(expression, node, position, size)
      elsif expression.is_a?(FunctionCall)
        call_function(expression, node, position, size)
      elsif expression.is_a?(LiteralExpr)
        expression.value
      elsif expression.is_a?(NumberExpr)
        expression.value
      elsif expression.is_a?(NegateExpr)
        -to_number(evaluate(expression.operand, node, position, size))
      elsif expression.is_a?(FilterExpr)
        evaluate_filter(expression, node, position, size)
      elsif expression.is_a?(VariableExpr)
        variable(expression.name)
      else
        raise XPathError.new("Unsupported expression #{expression.class}")
      end
    end

    private def variable(name : String) : Result
      value = @variables.try(&.[name]?)
      raise XPathError.new("Undefined XPath variable $#{name}") if value.nil?
      if value.is_a?(NodeSet)
        value.map do |node|
          unless node.document.same?(@document)
            raise XPathError.new("Variable $#{name} holds nodes from another document")
          end
          node.index
        end
      else
        value
      end
    end

    # --- Paths ----------------------------------------------------------------

    private def evaluate_path(path : PathExpr, node : Int32, position : Int32, size : Int32) : Result
      nodes = if filter = path.filter
                node_set(evaluate(filter, node, position, size), "a path step")
              elsif path.absolute?
                [0]
              else
                [node]
              end
      steps = path.list_of_steps
      index = 0
      while index < steps.size
        step = steps[index]
        following = steps[index + 1]?
        if following && step.descendant_or_self_node? && following.axis.child? && following.position_free?
          # `//name[pred]` equals `descendant::name[pred]` when the
          # predicates ignore proximity position: one scan instead of a
          # child step per descendant.
          nodes = apply_step(nodes, Axis::Descendant, following.test, following.list_of_predicates)
          index += 2
        else
          nodes = apply_step(nodes, step.axis, step.test, step.list_of_predicates)
          index += 1
        end
      end
      nodes
    end

    private def evaluate_filter(filter : FilterExpr, node : Int32, position : Int32, size : Int32) : Result
      nodes = node_set(evaluate(filter.primary, node, position, size), "a predicate")
      filter.list_of_predicates.each do |predicate|
        nodes = apply_predicate(nodes, predicate)
      end
      nodes
    end

    private def node_set(result : Result, context : String) : Array(Int32)
      return result if result.is_a?(Array(Int32))
      raise XPathError.new("Expected a node set before #{context}, got #{result.class}")
    end

    private def apply_step(contexts : Array(Int32), axis : Axis, test : NodeTest, predicates : Array(Expr)) : Array(Int32)
      matcher = resolve(test)
      result = [] of Int32
      candidates = [] of Int32
      contexts.each do |context|
        if predicates.empty?
          each_axis_node(context, axis) { |candidate| result << candidate if matches?(candidate, axis, matcher) }
        else
          candidates.clear
          each_axis_node(context, axis) { |candidate| candidates << candidate if matches?(candidate, axis, matcher) }
          selected = candidates
          predicates.each { |predicate| selected = apply_predicate(selected, predicate) }
          result.concat(selected)
        end
      end
      if contexts.size > 1 || axis.reverse?
        sort_unique(result)
      else
        result
      end
    end

    private def apply_predicate(nodes : Array(Int32), predicate : Expr) : Array(Int32)
      size = nodes.size
      selected = [] of Int32
      nodes.each_with_index do |node, offset|
        value = evaluate(predicate, node, offset + 1, size)
        keep = value.is_a?(Float64) ? value == offset + 1 : to_boolean(value)
        selected << node if keep
      end
      selected
    end

    private def sort_unique(nodes : Array(Int32)) : Array(Int32)
      return nodes if nodes.size < 2
      if @document.index_order?
        nodes.sort!
      else
        nodes.sort_by! { |node| @document.order_key(node) }
      end
      nodes.uniq!
      nodes
    end

    private def resolve(test : NodeTest) : Matcher
      local_id = -1
      uri_id = NameTable::EMPTY_ID
      if local = test.local
        local_id = @names.lookup(local.to_slice) unless test.kind.pi?
      end
      if prefix = test.prefix
        uri = @namespaces[prefix]? || raise XPathError.new("Undefined namespace prefix '#{prefix}'")
        uri_id = @names.lookup(uri.to_slice)
        uri_id = -2 if uri_id < 0
      end
      Matcher.new(test.kind, local_id, uri_id, test.kind.pi? ? test.local : nil)
    end

    private def matches?(node : Int32, axis : Axis, matcher : Matcher) : Bool
      kind = @document.kind(node)
      # XPath sees a run of adjacent text and CDATA nodes as one text node,
      # represented here by the first node of the run.
      return false if text_continuation?(node, kind)
      case matcher.kind
      when .any_node?
        true
      when .text?
        kind.text_node? || kind.cdata_section_node?
      when .comment?
        kind.comment_node?
      when .pi?
        return false unless kind.pi_node?
        target = matcher.target
        target.nil? || @names[@document.data(node).name_id] == target
      else
        principal = axis.attribute? ? kind.attribute_node? : kind.element_node?
        return false unless principal
        record = @document.data(node)
        case matcher.kind
        when .any_name?
          true
        when .namespace_any?
          record.namespace_uri_id == matcher.uri_id
        else
          record.namespace_uri_id == matcher.uri_id && @names.local_id(record.name_id) == matcher.local_id
        end
      end
    end

    private def attribute_like?(node : Int32) : Bool
      kind = @document.kind(node)
      kind.attribute_node? || kind.namespace_decl?
    end

    # Yields the nodes on *axis* from *node*, in axis order (reverse axes
    # yield the nearest node first).
    private def each_axis_node(node : Int32, axis : Axis, &) : Nil
      case axis
      when .child?
        return if attribute_like?(node)
        child = @document.data(node).first_child
        while child >= 0
          yield child
          child = @document.data(child).next_sibling
        end
      when .descendant?, .descendant_or_self?
        yield node if axis.descendant_or_self?
        return if attribute_like?(node)
        each_descendant(node) { |descendant| yield descendant }
      when .self?
        yield node
      when .parent?
        parent = @document.data(node).parent
        yield parent if parent >= 0
      when .ancestor?, .ancestor_or_self?
        yield node if axis.ancestor_or_self?
        parent = @document.data(node).parent
        while parent >= 0
          yield parent
          parent = @document.data(parent).parent
        end
      when .attribute?
        return unless @document.kind(node).element_node?
        attribute = @document.data(node).first_attribute
        while attribute >= 0
          yield attribute if @document.kind(attribute).attribute_node?
          attribute = @document.data(attribute).next_sibling
        end
      when .following_sibling?
        return if attribute_like?(node)
        sibling = @document.data(node).next_sibling
        while sibling >= 0
          yield sibling
          sibling = @document.data(sibling).next_sibling
        end
      when .preceding_sibling?
        return if attribute_like?(node)
        sibling = @document.data(node).previous_sibling
        while sibling >= 0
          yield sibling
          sibling = @document.data(sibling).previous_sibling
        end
      when .following?
        each_following(node) { |following| yield following }
      when .preceding?
        each_preceding(node).reverse_each { |preceding| yield preceding }
      end
    end

    private def each_descendant(node : Int32, &) : Nil
      if @document.index_order?
        stop = @document.subtree_end(node)
        current = node + 1
        while current < stop
          yield current unless attribute_like?(current)
          current += 1
        end
      else
        current = @document.following_in_order(node, node)
        while current >= 0
          yield current
          current = @document.following_in_order(current, node)
        end
      end
    end

    private def each_following(node : Int32, &) : Nil
      start = node
      if attribute_like?(node)
        start = @document.data(node).parent
        current = @document.following_in_order(start, 0)
      else
        current = -1
        walker = start
        while walker >= 0
          sibling = @document.data(walker).next_sibling
          if sibling >= 0
            current = sibling
            break
          end
          walker = @document.data(walker).parent
        end
      end
      while current >= 0
        yield current
        current = @document.following_in_order(current, 0)
      end
    end

    # Returns the preceding nodes in document order.
    private def each_preceding(node : Int32) : Array(Int32)
      target = attribute_like?(node) ? @document.data(node).parent : node
      ancestors = Set(Int32).new
      parent = @document.data(target).parent
      while parent >= 0
        ancestors << parent
        parent = @document.data(parent).parent
      end
      result = [] of Int32
      current = @document.following_in_order(0, 0)
      while current >= 0 && current != target
        result << current unless ancestors.includes?(current)
        current = @document.following_in_order(current, 0)
      end
      result
    end

    # --- Operators ------------------------------------------------------------

    private def evaluate_binary(expression : BinaryExpr, node : Int32, position : Int32, size : Int32) : Result
      operator = expression.operator
      case operator
      when "or"
        return true if to_boolean(evaluate(expression.left, node, position, size))
        return to_boolean(evaluate(expression.right, node, position, size))
      when "and"
        return false unless to_boolean(evaluate(expression.left, node, position, size))
        return to_boolean(evaluate(expression.right, node, position, size))
      end
      left = evaluate(expression.left, node, position, size)
      right = evaluate(expression.right, node, position, size)
      case operator
      when "|"
        sort_unique(node_set(left, "'|'") + node_set(right, "'|'"))
      when "=", "!=", "<", "<=", ">", ">="
        compare(operator, left, right)
      when "+"
        to_number(left) + to_number(right)
      when "-"
        to_number(left) - to_number(right)
      when "*"
        to_number(left) * to_number(right)
      when "div"
        to_number(left) / to_number(right)
      when "mod"
        dividend = to_number(left)
        divisor = to_number(right)
        dividend.nan? || divisor.nan? || divisor == 0 ? Float64::NAN : dividend - divisor * (dividend / divisor).trunc
      else
        raise XPathError.new("Unknown operator #{operator}")
      end
    end

    # Compares per XPath 1.0 section 3.4.
    private def compare(operator : String, left : Result, right : Result) : Bool
      if left.is_a?(Array(Int32)) && right.is_a?(Array(Int32))
        right_values = right.map { |node| string_value(node) }
        return left.any? do |node|
          left_value = string_value(node)
          right_values.any? { |right_value| compare_atoms(operator, left_value, right_value) }
        end
      end
      if left.is_a?(Array(Int32))
        return compare_atoms(operator, to_boolean(left), right) if right.is_a?(Bool)
        return left.any? { |node| compare_atoms(operator, node_atom(node, right), right) }
      end
      if right.is_a?(Array(Int32))
        return compare_atoms(operator, left, to_boolean(right)) if left.is_a?(Bool)
        return right.any? { |node| compare_atoms(operator, left, node_atom(node, left)) }
      end
      compare_atoms(operator, left, right)
    end

    # Converts node *node* to the type of *other* for comparison.
    private def node_atom(node : Int32, other : Result) : Result
      value = string_value(node)
      other.is_a?(Float64) ? XPath.string_to_number(value) : value
    end

    private def compare_atoms(operator : String, left : Result, right : Result) : Bool
      if operator == "=" || operator == "!="
        equal = if left.is_a?(Bool) || right.is_a?(Bool)
                  to_boolean(left) == to_boolean(right)
                elsif left.is_a?(Float64) || right.is_a?(Float64)
                  to_number(left) == to_number(right)
                else
                  to_string(left) == to_string(right)
                end
        return operator == "=" ? equal : !equal
      end
      left_number = to_number(left)
      right_number = to_number(right)
      case operator
      when "<"  then left_number < right_number
      when "<=" then left_number <= right_number
      when ">"  then left_number > right_number
      else           left_number >= right_number
      end
    end

    # --- Conversions ----------------------------------------------------------

    private def text_continuation?(node : Int32, kind : Node::Type) : Bool
      return false unless kind.text_node? || kind.cdata_section_node?
      previous = @document.data(node).previous_sibling
      return false if previous < 0
      previous_kind = @document.kind(previous)
      previous_kind.text_node? || previous_kind.cdata_section_node?
    end

    def string_value(node : Int32) : String
      Node.new(@document, node).xpath_string_value
    end

    def to_string(result : Result) : String
      case result
      when String
        result
      when Float64
        XPath.number_to_string(result)
      when Bool
        result ? "true" : "false"
      else
        result.empty? ? "" : string_value(result.first)
      end
    end

    def to_number(result : Result) : Float64
      case result
      when Float64
        result
      when Bool
        result ? 1.0 : 0.0
      when String
        XPath.string_to_number(result)
      else
        XPath.string_to_number(to_string(result))
      end
    end

    def to_boolean(result : Result) : Bool
      case result
      when Bool
        result
      when Float64
        !(result == 0 || result.nan?)
      when String
        !result.empty?
      else
        !result.empty?
      end
    end

    # --- Functions ------------------------------------------------------------

    private def call_function(call : FunctionCall, node : Int32, position : Int32, size : Int32) : Result
      arguments = call.list_of_arguments
      case call.name
      when "last"
        size.to_f64
      when "position"
        position.to_f64
      when "count"
        node_set(evaluate(arguments[0], node, position, size), "count()").size.to_f64
      when "local-name", "namespace-uri", "name"
        target = optional_node(arguments, node, position, size)
        target ? node_name_function(call.name, target) : ""
      when "string"
        arguments.empty? ? string_value(node) : to_string(evaluate(arguments[0], node, position, size))
      when "concat"
        String.build do |io|
          arguments.each { |argument| io << to_string(evaluate(argument, node, position, size)) }
        end
      when "starts-with"
        string_argument(arguments, 0, node, position, size).starts_with?(string_argument(arguments, 1, node, position, size))
      when "contains"
        string_argument(arguments, 0, node, position, size).includes?(string_argument(arguments, 1, node, position, size))
      when "substring-before"
        text = string_argument(arguments, 0, node, position, size)
        found = text.index(string_argument(arguments, 1, node, position, size))
        found ? text[0, found] : ""
      when "substring-after"
        text = string_argument(arguments, 0, node, position, size)
        needle = string_argument(arguments, 1, node, position, size)
        found = text.index(needle)
        found ? text[(found + needle.size)..] : ""
      when "substring"
        substring(arguments, node, position, size)
      when "string-length"
        text = arguments.empty? ? string_value(node) : string_argument(arguments, 0, node, position, size)
        text.size.to_f64
      when "normalize-space"
        text = arguments.empty? ? string_value(node) : string_argument(arguments, 0, node, position, size)
        text.split(/[ \t\r\n]+/, remove_empty: true).join(' ')
      when "translate"
        translate(arguments, node, position, size)
      when "not"
        !to_boolean(evaluate(arguments[0], node, position, size))
      when "true"
        true
      when "false"
        false
      when "boolean"
        to_boolean(evaluate(arguments[0], node, position, size))
      when "number"
        arguments.empty? ? XPath.string_to_number(string_value(node)) : to_number(evaluate(arguments[0], node, position, size))
      when "sum"
        node_set(evaluate(arguments[0], node, position, size), "sum()").sum(0.0) { |item| XPath.string_to_number(string_value(item)) }
      when "floor"
        to_number(evaluate(arguments[0], node, position, size)).floor
      when "ceiling"
        to_number(evaluate(arguments[0], node, position, size)).ceil
      when "round"
        XPath.round(to_number(evaluate(arguments[0], node, position, size)))
      else
        raise XPathError.new("Unknown XPath function #{call.name}()")
      end
    end

    private def string_argument(arguments : Array(Expr), index : Int32, node : Int32, position : Int32, size : Int32) : String
      to_string(evaluate(arguments[index], node, position, size))
    end

    private def optional_node(arguments : Array(Expr), node : Int32, position : Int32, size : Int32) : Int32?
      return node if arguments.empty?
      node_set(evaluate(arguments[0], node, position, size), "a name function").first?
    end

    private def node_name_function(name : String, node : Int32) : String
      kind = @document.kind(node)
      record = @document.data(node)
      case name
      when "namespace-uri"
        return "" unless kind.element_node? || kind.attribute_node?
        @names[record.namespace_uri_id]
      when "local-name"
        return @names[record.name_id] if kind.pi_node?
        return "" unless kind.element_node? || kind.attribute_node?
        @names[@names.local_id(record.name_id)]
      else
        return @names[record.name_id] if kind.pi_node? || kind.element_node? || kind.attribute_node?
        ""
      end
    end

    private def substring(arguments : Array(Expr), node : Int32, position : Int32, size : Int32) : String
      chars = string_argument(arguments, 0, node, position, size).chars
      start = XPath.round(to_number(evaluate(arguments[1], node, position, size)))
      finish = if arguments.size > 2
                 start + XPath.round(to_number(evaluate(arguments[2], node, position, size)))
               else
                 Float64::INFINITY
               end
      String.build do |io|
        chars.each_with_index do |char, offset|
          character_position = (offset + 1).to_f64
          io << char if character_position >= start && character_position < finish
        end
      end
    end

    private def translate(arguments : Array(Expr), node : Int32, position : Int32, size : Int32) : String
      text = string_argument(arguments, 0, node, position, size)
      from = string_argument(arguments, 1, node, position, size).chars
      to = string_argument(arguments, 2, node, position, size).chars
      String.build do |io|
        text.each_char do |char|
          found = from.index(char)
          if found.nil?
            io << char
          elsif found < to.size
            io << to[found]
          end
        end
      end
    end
  end
end
