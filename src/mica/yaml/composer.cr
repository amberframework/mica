module Mica::YAML
  # Builds node graphs from a `PullParser`'s events, one document at a
  # time, with an explicit stack (no recursion on the input's nesting).
  #
  # Aliases are resolved while composing: an alias becomes the node its
  # anchor names, without copying it. The composer still counts what the
  # copies would cost (`Node#expanded_size`) and raises `ParseLimitError`
  # ("max_alias_expansion") the moment a document would expand past the
  # limit, so a "billion laughs" document is stopped after a few dozen
  # events. An alias to a node that is still open (a node that would
  # contain itself) is rejected.
  #
  # ```
  # limits = Mica::YAML::ParseLimits::CONFIG_FILE
  # parser = Mica::YAML::PullParser.new("- &a x\n- *a\n", limits: limits, timeout: nil)
  # composer = Mica::YAML::Composer.new(parser, limits)
  # root = composer.next_document # => a Sequence whose two items are the same Scalar
  # composer.next_document        # => nil
  # ```
  class Composer
    private record Frame, node : Node, expanded : Int64, pending_key : Node?

    def initialize(@parser : PullParser, @limits : ParseLimits)
      @anchors = {} of String => Node
      @stack = [] of Frame
      @nodes = 0_i64
    end

    # Returns the root node of the next document, or nil at the end of the
    # stream.
    def next_document : Node?
      @parser.read_next if @parser.kind.stream_start?
      return nil unless @parser.kind.document_start?
      @anchors.clear
      @nodes = 0_i64
      @parser.read_next
      root = compose_node
      @parser.read_next # past the document end
      root
    end

    private def compose_node : Node
      loop do
        finished = nil
        position = @parser.start_position
        case @parser.kind
        when .scalar?
          node = Scalar.new(@parser.value, @parser.scalar_style, @parser.tag, @parser.anchor, @parser.start_position)
          register(node)
          finished = node
        when .alias?
          finished = resolve_alias
        when .sequence_start?
          node = Sequence.new(@parser.sequence_style, @parser.tag, @parser.anchor, @parser.start_position)
          count_node
          @stack << Frame.new(node, 1_i64, nil)
        when .mapping_start?
          node = Mapping.new(@parser.mapping_style, @parser.tag, @parser.anchor, @parser.start_position)
          count_node
          @stack << Frame.new(node, 1_i64, nil)
        when .sequence_end?, .mapping_end?
          frame = @stack.pop
          frame.node.expanded_size = frame.expanded
          if anchor = frame.node.anchor
            @anchors[anchor] = frame.node
          end
          finished = frame.node
        else
          raise Mica::Error.new("Unexpected #{@parser.kind} event while composing")
        end
        @parser.read_next
        next unless finished
        return finished if @stack.empty?
        attach(finished, position)
      end
    end

    # Adds a finished node to the collection on top of the stack and
    # charges its expanded size to it. *position* is where the node, or the
    # alias that stands for it, was written.
    private def attach(node : Node, position : Core::Position) : Nil
      frame = @stack.pop
      expanded = frame.expanded
      expanded = node.expanded_size > Int64::MAX - expanded ? Int64::MAX : expanded + node.expanded_size
      if expanded > @limits.max_alias_expansion
        raise ParseLimitError.new(
          "Aliases expand the document past max_alias_expansion (#{@limits.max_alias_expansion} nodes)",
          position, "max_alias_expansion")
      end
      parent = frame.node
      pending_key = nil
      if parent.is_a?(Sequence)
        parent.list_of_items << node
      elsif parent.is_a?(Mapping)
        if key = frame.pending_key
          parent.list_of_pairs << {key, node}
        else
          pending_key = node
        end
      end
      @stack << Frame.new(parent, expanded, pending_key)
    end

    private def count_node : Nil
      @nodes += 1
      if @nodes > @limits.max_nodes
        raise ParseLimitError.new("The document has more than max_nodes (#{@limits.max_nodes}) nodes",
          @parser.start_position, "max_nodes")
      end
      if @parser.meter.charge(1)
        @parser.meter.enforce("while composing") { @parser.start_position }
      end
    end

    private def register(node : Node) : Nil
      count_node
      if anchor = node.anchor
        @anchors[anchor] = node
      end
    end

    private def resolve_alias : Node
      count_node
      name = @parser.anchor || ""
      if target = @anchors[name]?
        return target
      end
      if @stack.any? { |frame| frame.node.anchor == name }
        raise SyntaxError.new("found an alias to the node that contains it", @parser.start_position)
      end
      raise UnknownAnchorError.new("found undefined alias", @parser.start_position)
    end
  end
end
