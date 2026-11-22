module Mica::YAML
  # What to do when a mapping names the same key twice.
  enum DuplicateKeys
    # The later value replaces the earlier one (what libyaml-based
    # parsers do).
    LastWins
    # Raise `SyntaxError` at the second key.
    Reject
  end

  # Turns a composed node graph into `Any` values under a `Schema`, with
  # an explicit stack. A node reached through several aliases is converted
  # once and shared.
  #
  # With *merge_keys*, a mapping entry whose key is the plain scalar `<<`
  # merges its value (a mapping, or a sequence of mappings) into the
  # mapping: keys the mapping writes itself always win, and among merged
  # mappings the first one to name a key wins. Each merged entry counts
  # against `max_alias_expansion`.
  #
  # :nodoc:
  class Resolver
    private STR_TAG   = "tag:yaml.org,2002:str"
    private INT_TAG   = "tag:yaml.org,2002:int"
    private FLOAT_TAG = "tag:yaml.org,2002:float"
    private BOOL_TAG  = "tag:yaml.org,2002:bool"
    private NULL_TAG  = "tag:yaml.org,2002:null"
    private MERGE_TAG = "tag:yaml.org,2002:merge"

    private class Frame
      getter node : Node
      getter any : Any
      property index : Int32 = 0
      property key : Any?

      def initialize(@node : Node, @any : Any)
      end
    end

    def initialize(@schema : Schema, @merge_keys : Bool, @duplicate_keys : DuplicateKeys, @limits : ParseLimits,
                   @meter : Core::WorkMeter)
      @memo = {} of UInt64 => Any
      @stack = [] of Frame
      @merged = 0_i64
    end

    # Returns the value of the graph under *root*.
    def resolve(root : Node) : Any
      result = value_of(root)
      while frame = @stack.last?
        node = frame.node
        if node.is_a?(Sequence)
          if frame.index < node.list_of_items.size
            child = node.list_of_items[frame.index]
            frame.index += 1
            frame.any.as_a << value_of(child)
          else
            @stack.pop
          end
        elsif node.is_a?(Mapping)
          step_mapping(frame, node)
        end
      end
      result
    end

    # Moves a mapping frame one step: converts the next key, or the value
    # after it, and stores the pair once both are complete (a collection
    # used as a key is filled before it is hashed).
    private def step_mapping(frame : Frame, node : Mapping) : Nil
      if frame.index >= node.list_of_pairs.size
        @stack.pop
        return
      end
      key_node, value_node = node.list_of_pairs[frame.index]
      key = frame.key
      unless key
        frame.key = value_of(key_node)
        return
      end
      was_open = @stack.size
      value = value_of(value_node)
      if @stack.size > was_open
        # The value is a collection that is not filled yet: finish it
        # first. It is memoized, so the next visit takes the branch below.
        return
      end
      frame.key = nil
      frame.index += 1
      store(frame.any.as_h, key_node, key, value)
    end

    private def store(hash : Hash(Any, Any), key_node : Node, key : Any, value : Any) : Nil
      if @merge_keys && merge_key?(key_node)
        raw = value.raw
        if raw.is_a?(Hash)
          merge(hash, raw, key_node)
          return
        elsif raw.is_a?(Array) && raw.all?(&.raw.is_a?(Hash))
          raw.each { |item| merge(hash, item.as_h, key_node) }
          return
        end
      end
      if @duplicate_keys.reject? && hash.has_key?(key)
        raise SyntaxError.new("found duplicate key", key_node.position)
      end
      hash[key] = value
    end

    private def merge_key?(node : Node) : Bool
      return false unless node.is_a?(Scalar) && node.value == "<<"
      tag = node.tag
      tag ? tag == MERGE_TAG : node.style.plain?
    end

    private def merge(hash : Hash(Any, Any), other : Hash(Any, Any), key_node : Node) : Nil
      @merged = other.size > Int64::MAX - @merged ? Int64::MAX : @merged + other.size
      if @merged > @limits.max_alias_expansion
        raise ParseLimitError.new("Merge keys copy more than max_alias_expansion (#{@limits.max_alias_expansion}) entries",
          key_node.position, "max_alias_expansion")
      end
      @meter.enforce("while merging") { key_node.position } if @meter.charge(other.size)
      other.each do |key, value|
        hash[key] = value unless hash.has_key?(key)
      end
    end

    # Returns the value of *node*: a scalar's at once, a collection's as an
    # empty array or hash that the main loop fills (pushed on the stack the
    # first time it is seen).
    private def value_of(node : Node) : Any
      if node.is_a?(Scalar)
        return scalar_value(node)
      end
      id = node.object_id
      if known = @memo[id]?
        return known
      end
      @meter.enforce("while resolving") { node.position } if @meter.charge(1)
      if node.is_a?(Sequence)
        any = Any.new(Array(Any).new(node.list_of_items.size))
        @memo[id] = any
        @stack << Frame.new(node, any)
        any
      elsif node.is_a?(Mapping)
        any = Any.new(Hash(Any, Any).new(initial_capacity: node.list_of_pairs.size))
        @memo[id] = any
        @stack << Frame.new(node, any)
        any
      else
        raise Mica::Error.new("Unknown node type")
      end
    end

    private def scalar_value(node : Scalar) : Any
      tag = node.tag
      text = node.value
      if tag.nil?
        return Any.new(node.style.plain? ? @schema.resolve(text) : text)
      end
      return Any.new(text) if @schema.fail_safe? || tag == STR_TAG || tag == "!"
      value = Schema::Core.resolve(text)
      if tag == INT_TAG
        return Any.new(value) if value.is_a?(Int64)
      elsif tag == FLOAT_TAG
        return Any.new(value.to_f64) if value.is_a?(Int64)
        return Any.new(value) if value.is_a?(Float64)
      elsif tag == BOOL_TAG
        return Any.new(value) if value.is_a?(Bool)
      elsif tag == NULL_TAG
        return Any.new(nil) if value.nil?
      else
        # An application tag this schema does not know: keep the text.
        return Any.new(text)
      end
      raise SyntaxError.new("found a scalar that does not match its tag #{Core.quote(tag)}", node.position)
    end
  end
end
