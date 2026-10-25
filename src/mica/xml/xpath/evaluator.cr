module Mica::XML::XPath
  # :nodoc:
  #
  # Evaluates a parsed expression against one document. Node sets are
  # arrays of arena indices kept in document order.
  #
  # Every node visit, predicate evaluation, sort and string byte is charged
  # to a `Core::WorkMeter`. Axis steps whose predicates ignore the proximity
  # position are evaluated once over the union of their contexts, so each
  # such step is linear in the document size plus its result; positional
  # steps are evaluated per context, as XPath requires, and are bounded by
  # the budget.
  class Evaluator
    alias Result = Array(Int32) | String | Float64 | Bool

    # Resolved form of a node test.
    private record Matcher, kind : TestKind, local_id : Int32, uri_id : Int32, target : String?

    @names : NameTable
    @offset = 0

    # Without *namespaces*, the prefixes declared on the document element
    # are used; collecting them is charged to *meter*.
    def initialize(@document : Document, namespaces : Hash(String, String)?, @variables : Hash(String, Value)?,
                   @meter : Core::WorkMeter, @source : String)
      @names = @document.names
      @namespace_aware = @document.namespace_aware?
      @namespaces = namespaces || {} of String => String
      collect_root_namespaces unless namespaces
    end

    # Reads the namespace declarations of the document element into
    # `@namespaces`, charging each node visited and each URI byte copied
    # before the copy.
    private def collect_root_namespaces : Nil
      child = @document.data(0).first_child
      while child >= 0
        charge(1)
        break if @document.kind(child).element_node?
        child = @document.data(child).next_sibling
      end
      return if child < 0
      attribute = @document.data(child).first_attribute
      while attribute >= 0
        record = @document.data(attribute)
        charge(1)
        if record.kind.namespace_decl?
          value = @document.value_bytes(attribute)
          charge(value.size)
          prefix_id = @document.declared_prefix_id(record.name_id)
          prefix = prefix_id == NameTable::EMPTY_ID ? "xmlns" : @names[prefix_id]
          # The prefix is hashed into the table.
          charge(prefix.bytesize)
          @namespaces[prefix] = String.new(value)
        end
        attribute = record.next_sibling
      end
    end

    def run(expression : Expr, context : Int32) : Value
      to_value(evaluate(expression, text_run_start(context), 1, 1))
    end

    # Evaluates and converts with `string()`, charging the conversion.
    def run_string(expression : Expr, context : Int32) : String
      to_string(evaluate(expression, text_run_start(context), 1, 1))
    end

    # Evaluates and converts with `number()`, charging the conversion.
    def run_number(expression : Expr, context : Int32) : Float64
      to_number(evaluate(expression, text_run_start(context), 1, 1))
    end

    # Evaluates and converts with `boolean()`.
    def run_boolean(expression : Expr, context : Int32) : Bool
      to_boolean(evaluate(expression, text_run_start(context), 1, 1))
    end

    # Charges *count* operations and raises when the budget or the deadline
    # trips. The error's position is the expression being evaluated.
    @[AlwaysInline]
    private def charge(count : Int) : Nil
      work_limit_reached if @meter.charge(count)
    end

    private def work_limit_reached : Nil
      verdict = @meter.verdict
      return if verdict.within?
      @meter.raise_exceeded(verdict, expression_position, expression_context)
    end

    # The expression, quoted (at most `XPath::EXCERPT_CHARS` characters),
    # for budget messages.
    private def expression_context : String
      "in XPath #{XPath.quote(@source)}"
    end

    # The position of the expression part being evaluated: line 1, the
    # column in characters and the byte offset.
    private def expression_position : Core::Position
      XPath.expression_position(@source, @offset)
    end

    # XPath sees a run of adjacent text and CDATA siblings as one node, so a
    # context inside a run is moved to the run's first node.
    private def text_run_start(node : Int32) : Int32
      current = node
      while text_continuation?(current, @document.kind(current))
        charge(1)
        current = @document.data(current).previous_sibling
      end
      current
    end

    private def to_value(result : Result) : Value
      if result.is_a?(Array(Int32))
        charge(result.size)
        NodeSet.new(result.map { |index| Node.new(@document, index) })
      else
        result
      end
    end

    def evaluate(expression : Expr, node : Int32, position : Int32, size : Int32) : Result
      @offset = expression.offset
      charge(1)
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
      # The name is hashed for the lookup.
      charge(name.bytesize + 1)
      value = @variables.try(&.[name]?)
      raise XPathError.new("Undefined XPath variable $#{XPath.excerpt(name)}") if value.nil?
      if value.is_a?(NodeSet)
        charge(value.size)
        nodes = value.map do |node|
          unless node.document.same?(@document)
            raise XPathError.new("Variable $#{XPath.excerpt(name)} holds nodes from another document")
          end
          node.index
        end
        sort_unique(nodes)
      else
        charge(value.bytesize) if value.is_a?(String)
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
        @offset = step.offset
        following = steps[index + 1]?
        if following && step.descendant_or_self_node? && following.axis.child? && following.position_free?
          # `//name[pred]` equals `descendant::name[pred]` when the
          # predicates ignore proximity position: one scan instead of a
          # child step per descendant.
          nodes = apply_step(nodes, Axis::Descendant, following.test, following.list_of_predicates, true)
          index += 2
        else
          nodes = apply_step(nodes, step.axis, step.test, step.list_of_predicates, step.position_free?)
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

    # *contexts* are in document order. When the step's predicates ignore
    # the proximity position, the step runs once over the union of the
    # contexts' axes (each node visited once); otherwise it runs per
    # context, as the predicates' positions depend on it.
    private def apply_step(contexts : Array(Int32), axis : Axis, test : NodeTest, predicates : Array(Expr), position_free : Bool) : Array(Int32)
      matcher = resolve(test)
      if position_free || contexts.size <= 1
        result = [] of Int32
        each_axis_node_of_all(contexts, axis) do |candidate|
          result << candidate if matches?(candidate, axis, matcher)
        end
        result = sort_unique(result) if contexts.size > 1 || axis.reverse?
        predicates.each { |predicate| result = apply_predicate(result, predicate) }
        return result
      end
      result = [] of Int32
      candidates = [] of Int32
      contexts.each do |context|
        candidates.clear
        each_axis_node(context, axis) { |candidate| candidates << candidate if matches?(candidate, axis, matcher) }
        selected = candidates
        predicates.each { |predicate| selected = apply_predicate(selected, predicate) }
        result.concat(selected)
      end
      sort_unique(result)
    end

    # Evaluates *predicate* for each node. *nodes* are in axis order, or in
    # document order for a union step, whose predicates never read the
    # proximity position.
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
        # Often already in order (a child step over contexts in document
        # order): one pass checks, and the sort is skipped.
        charge(nodes.size)
        return nodes if strictly_increasing?(nodes)
      end
      # Comparison sort: n log2 n comparisons.
      charge(nodes.size * (64 - nodes.size.leading_zeros_count))
      if @document.index_order?
        nodes.sort!
      else
        charge(@document.node_count) unless @document.order_keys_ready?
        nodes.sort_by! { |node| @document.order_key(node) }
      end
      drop_adjacent_duplicates(nodes)
    end

    private def strictly_increasing?(nodes : Array(Int32)) : Bool
      index = 1
      while index < nodes.size
        return false unless nodes[index - 1] < nodes[index]
        index += 1
      end
      true
    end

    # Removes repeats from sorted *nodes* in place (no hashing).
    private def drop_adjacent_duplicates(nodes : Array(Int32)) : Array(Int32)
      kept = 0
      nodes.each_with_index do |node, index|
        next if index > 0 && node == nodes[kept - 1]
        nodes[kept] = node
        kept += 1
      end
      nodes.truncate(0, kept)
    end

    private def resolve(test : NodeTest) : Matcher
      local_id = -1
      uri_id = NameTable::EMPTY_ID
      # Hashing and comparing names is charged before it happens (the bytes
      # hashed and one compare each); probes beyond that are charged after.
      prepaid = 0_i64
      uri = nil
      if prefix = test.prefix
        charge(prefix.bytesize + 1)
        uri = @namespaces[prefix]? || raise XPathError.new("Undefined namespace prefix '#{XPath.excerpt(prefix)}'")
        prepaid += 2 * uri.bytesize + 2
      end
      # The local name, or a processing-instruction target, becomes a name
      # id here, so matching compares ids.
      local = test.local
      prepaid += 2 * local.bytesize + 2 if local
      charge(prepaid)
      name_operations = @names.lookup_operations
      local_id = @names.lookup(local.to_slice) if local
      if uri
        uri_id = @names.lookup(uri.to_slice)
        uri_id = -2 if uri_id < 0
      end
      charge(Math.max(@names.lookup_operations - name_operations - prepaid, 0_i64))
      Matcher.new(test.kind, local_id, uri_id, test.kind.pi? ? test.local : nil)
    end

    private def matches?(node : Int32, axis : Axis, matcher : Matcher) : Bool
      kind = @document.kind(node)
      # XPath sees a run of adjacent text and CDATA nodes as one text node,
      # represented here by the first node of the run. Only the tests that
      # accept text nodes need the check.
      case matcher.kind
      when .any_node?
        !text_continuation?(node, kind)
      when .text?
        (kind.text_node? || kind.cdata_section_node?) && !text_continuation?(node, kind)
      when .comment?
        kind.comment_node?
      when .pi?
        return false unless kind.pi_node?
        matcher.target.nil? || @document.data(node).name_id == matcher.local_id
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
          # Without namespace processing a name is one unit ("p:a" is not
          # an "a"), so the test compares whole names and never splits one.
          name_id = @namespace_aware ? @document.split_local_id(record.name_id) : record.name_id
          record.namespace_uri_id == matcher.uri_id && name_id == matcher.local_id
        end
      end
    end

    private def attribute_like?(node : Int32) : Bool
      kind = @document.kind(node)
      kind.attribute_node? || kind.namespace_decl?
    end

    # Yields every node on *axis* from any of *contexts* (in document
    # order), each at most once, visiting O(document + result) nodes.
    private def each_axis_node_of_all(contexts : Array(Int32), axis : Axis, & : Int32 ->) : Nil
      if contexts.size == 1
        each_axis_node(contexts[0], axis) { |node| yield node }
        return
      end
      case axis
      when .child?, .attribute?, .self?
        # Disjoint for distinct contexts.
        contexts.each { |context| each_axis_node(context, axis) { |node| yield node } }
      when .descendant?, .descendant_or_self?
        covered_until = -1
        visited = Set(Int32).new
        contexts.each do |context|
          if @document.index_order?
            # A context inside an earlier context's subtree adds nothing.
            next if context < covered_until && !attribute_like?(context)
            covered_until = Math.max(covered_until, @document.subtree_end(context)) unless attribute_like?(context)
            each_axis_node(context, axis) { |node| yield node }
          else
            next if visited.includes?(context)
            yield context if axis.descendant_or_self?
            next if attribute_like?(context)
            each_descendant(context) do |node|
              charge(1)
              yield node if visited.add?(node)
            end
          end
        end
      when .parent?
        visited = Set(Int32).new
        contexts.each do |context|
          parent = @document.data(context).parent
          yield parent if parent >= 0 && visited.add?(parent)
        end
      when .ancestor?, .ancestor_or_self?
        visited = Set(Int32).new
        contexts.each do |context|
          if axis.ancestor_or_self?
            next unless visited.add?(context)
            yield context
          end
          parent = @document.data(context).parent
          # Stop at an ancestor already reached: its ancestors were too.
          while parent >= 0 && visited.add?(parent)
            charge(1)
            yield parent
            parent = @document.data(parent).parent
          end
        end
      when .following_sibling?
        visited = Set(Int32).new
        contexts.each do |context|
          next if attribute_like?(context)
          sibling = @document.data(context).next_sibling
          # A later context's siblings were walked by an earlier one.
          while sibling >= 0 && visited.add?(sibling)
            charge(1)
            yield sibling
            sibling = @document.data(sibling).next_sibling
          end
        end
      when .preceding_sibling?
        visited = Set(Int32).new
        contexts.reverse_each do |context|
          next if attribute_like?(context)
          sibling = @document.data(context).previous_sibling
          while sibling >= 0 && visited.add?(sibling)
            charge(1)
            yield sibling
            sibling = @document.data(sibling).previous_sibling
          end
        end
      when .following?
        # following(c) holds every node after c's subtree, so the union is
        # following(c) for the context whose subtree ends first. Attributes
        # of one element share their following start: it is found once.
        best = earliest_following_context(contexts)
        each_axis_node(best, axis) { |node| yield node } if best
      when .preceding?
        # preceding(x) is contained in preceding(y) whenever y comes after
        # x, so the union is preceding(last context).
        best = contexts.max_by? { |context| order_of(attribute_like?(context) ? @document.data(context).parent : context) }
        each_axis_node(best, axis) { |node| yield node } if best
      end
    end

    private def order_of(node : Int32) : Int32
      charge(@document.node_count) unless @document.order_keys_ready?
      @document.order_key(node)
    end

    # Returns the context whose following axis starts first (nil for no
    # contexts). Each owner element of attribute contexts is examined once.
    private def earliest_following_context(contexts : Array(Int32)) : Int32?
      owners = Set(Int32).new
      best = nil
      best_order = Int32::MAX
      contexts.each do |context|
        charge(1)
        next if attribute_like?(context) && !owners.add?(@document.data(context).parent)
        start = following_start(context)
        order = start < 0 ? Int32::MAX : order_of(start)
        if best.nil? || order < best_order
          best = context
          best_order = order
        end
      end
      best
    end

    # Returns the first node of the following axis of *node*, or -1. Each
    # step of the climb is charged.
    private def following_start(node : Int32) : Int32
      if attribute_like?(node)
        # An attribute's following axis starts at its element's first
        # child, or else where the element's own following axis starts.
        owner = @document.data(node).parent
        first = @document.data(owner).first_child
        return first if first >= 0
        node = owner
      end
      walker = node
      while walker >= 0
        charge(1)
        sibling = @document.data(walker).next_sibling
        return sibling if sibling >= 0
        walker = @document.data(walker).parent
      end
      -1
    end

    # Yields the nodes on *axis* from *node*, in axis order (reverse axes
    # yield the nearest node first).
    private def each_axis_node(node : Int32, axis : Axis, &) : Nil
      case axis
      when .child?
        return if attribute_like?(node)
        child = @document.data(node).first_child
        while child >= 0
          charge(1)
          yield child
          child = @document.data(child).next_sibling
        end
      when .descendant?, .descendant_or_self?
        yield node if axis.descendant_or_self?
        return if attribute_like?(node)
        # each_descendant charges every node it visits.
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
          charge(1)
          yield parent
          parent = @document.data(parent).parent
        end
      when .attribute?
        return unless @document.kind(node).element_node?
        attribute = @document.data(node).first_attribute
        while attribute >= 0
          charge(1)
          yield attribute if @document.kind(attribute).attribute_node?
          attribute = @document.data(attribute).next_sibling
        end
      when .following_sibling?
        return if attribute_like?(node)
        sibling = @document.data(node).next_sibling
        while sibling >= 0
          charge(1)
          yield sibling
          sibling = @document.data(sibling).next_sibling
        end
      when .preceding_sibling?
        return if attribute_like?(node)
        sibling = @document.data(node).previous_sibling
        while sibling >= 0
          charge(1)
          yield sibling
          sibling = @document.data(sibling).previous_sibling
        end
      when .following?
        each_following(node) { |following| yield following }
      when .preceding?
        each_preceding(node).reverse_each { |preceding| yield preceding }
      end
    end

    # Nodes a descendant walk visits per work charge.
    private WALK_CHUNK = 1024

    private def each_descendant(node : Int32, &) : Nil
      if @document.index_order?
        stop = @document.subtree_end(node)
        current = node + 1
        while current < stop
          # Each chunk is charged before it is walked, so a long walk stops
          # between chunks and never runs past the budget.
          chunk_end = stop - current > WALK_CHUNK ? current + WALK_CHUNK : stop
          charge(chunk_end - current)
          while current < chunk_end
            yield current unless attribute_like?(current)
            current += 1
          end
        end
      else
        current = @document.following_in_order(node, node)
        while current >= 0
          charge(1)
          yield current
          current = @document.following_in_order(current, node)
        end
      end
    end

    private def each_following(node : Int32, &) : Nil
      current = following_start(node)
      while current >= 0
        charge(1)
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
        charge(1)
        ancestors << parent
        parent = @document.data(parent).parent
      end
      result = [] of Int32
      current = @document.following_in_order(0, 0)
      while current >= 0 && current != target
        charge(1)
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
      @offset = expression.offset
      case operator
      when "|"
        left_nodes = node_set(left, "'|'")
        right_nodes = node_set(right, "'|'")
        charge(left_nodes.size + right_nodes.size)
        union = left_nodes + right_nodes
        sort_unique(union)
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

    # Compares per XPath 1.0 section 3.4, in time linear in the sizes of the
    # operands.
    private def compare(operator : String, left : Result, right : Result) : Bool
      if left.is_a?(Array(Int32)) && right.is_a?(Array(Int32))
        return compare_node_sets(operator, left, right)
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

    # Node set against node set: true when some pair of string values (for
    # `=` and `!=`) or numbers (for the relational operators) satisfies the
    # operator.
    private def compare_node_sets(operator : String, left : Array(Int32), right : Array(Int32)) : Bool
      return false if left.empty? || right.empty?
      case operator
      when "="
        right_values = Set(String).new
        right.each { |node| right_values << string_value(node) }
        left.any? { |node| right_values.includes?(string_value(node)) }
      when "!="
        # Some pair differs unless both sides hold one and the same value.
        first = string_value(right[0])
        right_distinct = right.any? { |node| string_value(node) != first }
        return true if right_distinct
        left.any? { |node| string_value(node) != first }
      else
        left_low, left_high = number_range(left)
        right_low, right_high = number_range(right)
        return false if left_low.nan? || right_low.nan?
        case operator
        when "<"  then left_low < right_high
        when "<=" then left_low <= right_high
        when ">"  then left_high > right_low
        else           left_high >= right_low
        end
      end
    end

    # Returns the smallest and largest number among the nodes' values,
    # ignoring NaN (comparisons with NaN are false); NaN, NaN when every
    # value is NaN.
    private def number_range(nodes : Array(Int32)) : {Float64, Float64}
      low = Float64::NAN
      high = Float64::NAN
      nodes.each do |node|
        number = XPath.string_to_number(string_value(node))
        next if number.nan?
        low = number if low.nan? || number < low
        high = number if high.nan? || number > high
      end
      {low, high}
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
                  left_string = to_string(left)
                  right_string = to_string(right)
                  # Literals are compared again for every context node.
                  charge(Math.min(left_string.bytesize, right_string.bytesize) + 1)
                  left_string == right_string
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

    # Returns the XPath string value of *node*, charging the nodes walked
    # and the bytes copied.
    def string_value(node : Int32) : String
      kind = @document.kind(node)
      if kind.element_node? || kind.document_node?
        return String.build do |io|
          each_text_in_subtree(node) { |bytes| io.write(bytes) }
        end
      end
      if kind.text_node? || kind.cdata_section_node?
        return String.build do |io|
          current = node
          while current >= 0
            current_kind = @document.kind(current)
            break unless current_kind.text_node? || current_kind.cdata_section_node?
            bytes = @document.value_bytes(current)
            charge(1 + bytes.size)
            io.write(bytes)
            current = @document.data(current).next_sibling
          end
        end
      end
      value = Node.new(@document, node).content
      charge(1 + value.bytesize)
      value
    end

    private def each_text_in_subtree(node : Int32, & : Bytes ->) : Nil
      if @document.index_order?
        stop = @document.subtree_end(node)
        current = node + 1
        while current < stop
          kind = @document.kind(current)
          if kind.text_node? || kind.cdata_section_node?
            bytes = @document.value_bytes(current)
            charge(1 + bytes.size)
            yield bytes
          else
            charge(1)
          end
          current += 1
        end
      else
        current = @document.following_in_order(node, node)
        while current >= 0
          kind = @document.kind(current)
          if kind.text_node? || kind.cdata_section_node?
            bytes = @document.value_bytes(current)
            charge(1 + bytes.size)
            yield bytes
          else
            charge(1)
          end
          current = @document.following_in_order(current, node)
        end
      end
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
        charge(result.bytesize)
        XPath.string_to_number(result)
      else
        text = to_string(result)
        charge(text.bytesize)
        XPath.string_to_number(text)
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
          arguments.each do |argument|
            text = to_string(evaluate(argument, node, position, size))
            charge(text.bytesize)
            io << text
          end
        end
      when "starts-with"
        text = string_argument(arguments, 0, node, position, size)
        prefix = string_argument(arguments, 1, node, position, size)
        charge(prefix.bytesize)
        text.starts_with?(prefix)
      when "contains"
        text = string_argument(arguments, 0, node, position, size)
        !search(text, string_argument(arguments, 1, node, position, size)).nil?
      when "substring-before"
        text = string_argument(arguments, 0, node, position, size)
        found = search(text, string_argument(arguments, 1, node, position, size))
        return "" unless found
        # The prefix copy is charged before it happens.
        charge(found)
        text.byte_slice(0, found)
      when "substring-after"
        text = string_argument(arguments, 0, node, position, size)
        needle = string_argument(arguments, 1, node, position, size)
        found = search(text, needle)
        return "" unless found
        # The search stopped at the match: the suffix copy is charged here.
        charge(text.bytesize - found - needle.bytesize)
        text.byte_slice(found + needle.bytesize)
      when "substring"
        substring(arguments, node, position, size)
      when "string-length"
        text = arguments.empty? ? string_value(node) : string_argument(arguments, 0, node, position, size)
        charge(text.bytesize)
        text.size.to_f64
      when "normalize-space"
        text = arguments.empty? ? string_value(node) : string_argument(arguments, 0, node, position, size)
        charge(text.bytesize)
        XPath.normalize_space(text)
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
        arguments.empty? ? to_number(string_value(node)) : to_number(evaluate(arguments[0], node, position, size))
      when "sum"
        node_set(evaluate(arguments[0], node, position, size), "sum()").sum(0.0) { |summed_node| to_number(string_value(summed_node)) }
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

    # Returns the byte offset of *needle* in *text*, in linear time.
    private def search(text : String, needle : String) : Int32?
      Core::ByteSearch.index(text.to_slice, needle.to_slice) { |steps| charge(steps) }
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
        # Without namespace processing a name has no local part to split
        # off (and splitting would intern uncharged work).
        return @names[record.name_id] unless @namespace_aware
        @names[@document.split_local_id(record.name_id)]
      else
        return @names[record.name_id] if kind.pi_node? || kind.element_node? || kind.attribute_node?
        ""
      end
    end

    private def substring(arguments : Array(Expr), node : Int32, position : Int32, size : Int32) : String
      text = string_argument(arguments, 0, node, position, size)
      charge(text.bytesize)
      start = XPath.round(to_number(evaluate(arguments[1], node, position, size)))
      finish = if arguments.size > 2
                 start + XPath.round(to_number(evaluate(arguments[2], node, position, size)))
               else
                 Float64::INFINITY
               end
      String.build do |io|
        text.each_char_with_index do |char, offset|
          character_position = (offset + 1).to_f64
          io << char if character_position >= start && character_position < finish
        end
      end
    end

    # translate(text, from, to): one hash lookup per character of *text*.
    private def translate(arguments : Array(Expr), node : Int32, position : Int32, size : Int32) : String
      text = string_argument(arguments, 0, node, position, size)
      from = string_argument(arguments, 1, node, position, size)
      replacement = string_argument(arguments, 2, node, position, size)
      charge(text.bytesize + from.bytesize + replacement.bytesize)
      to = replacement.chars
      mapping = {} of Char => Char?
      from.each_char_with_index do |char, index|
        mapping[char] = to[index]? unless mapping.has_key?(char)
      end
      String.build do |io|
        text.each_char do |char|
          if mapping.has_key?(char)
            replacement = mapping[char]
            io << replacement if replacement
          else
            io << char
          end
        end
      end
    end
  end
end
