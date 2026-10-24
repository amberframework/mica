class Mica::Reader
  # Applies Namespaces in XML 1.0 to the current start tag, after DTD
  # defaults were added: binds the tag's declarations, then resolves the
  # element and attribute prefixes, then checks expanded attribute names for
  # duplicates. Returns the binding stack size before this tag's bindings.
  private def process_namespaces(element_id : Int32) : Int32
    binding_mark = @binding_prefixes.size
    count = @attrs.size
    index = 0
    while index < count
      slot = @attrs.unsafe_fetch(index)
      attr_id = slot.name_id
      unless @names.qname?(attr_id)
        syntax_error("Attribute name '#{@names[attr_id]}' is not a valid QName")
      end
      if attr_id == @xmlns_id
        bind_default_namespace(slot)
        @attrs[index] = slot.copy_with(namespace_uri_id: @xmlns_namespace_id)
      elsif @names.prefix_id(attr_id) == @xmlns_id
        bind_prefix(slot)
        @attrs[index] = slot.copy_with(namespace_uri_id: @xmlns_namespace_id)
      end
      index += 1
    end

    unless @names.qname?(element_id)
      syntax_error("Element name '#{@names[element_id]}' is not a valid QName")
    end
    element_prefix = @names.prefix_id(element_id)
    if element_prefix == @xmlns_id
      syntax_error("Element name '#{@names[element_id]}' must not use the xmlns prefix")
    end
    @namespace_uri_id = resolve_prefix(element_prefix, element_id)

    prefixed = 0
    index = 0
    while index < count
      slot = @attrs.unsafe_fetch(index)
      if slot.namespace_uri_id == NameTable::EMPTY_ID
        attr_prefix = @names.prefix_id(slot.name_id)
        unless attr_prefix == NameTable::EMPTY_ID
          @attrs[index] = slot.copy_with(namespace_uri_id: resolve_prefix(attr_prefix, slot.name_id))
          prefixed += 1
        end
      end
      index += 1
    end
    check_expanded_attribute_names if prefixed > 1
    binding_mark
  end

  private def bind_default_namespace(slot : AttributeSlot) : Nil
    uri_id = @names.intern(attribute_value_bytes(slot))
    if uri_id == @xml_namespace_id || uri_id == @xmlns_namespace_id
      syntax_error("The default namespace cannot be '#{@names[uri_id]}'")
    end
    @binding_prefixes << NameTable::EMPTY_ID
    @binding_uris << uri_id
  end

  private def bind_prefix(slot : AttributeSlot) : Nil
    prefix_id = @names.local_id(slot.name_id)
    uri_id = @names.intern(attribute_value_bytes(slot))
    if prefix_id == @xml_id
      unless uri_id == @xml_namespace_id
        syntax_error("The xml prefix must be bound to #{XML_NAMESPACE}")
      end
      return
    end
    if prefix_id == @xmlns_id
      syntax_error("The xmlns prefix must not be declared")
    end
    if uri_id == NameTable::EMPTY_ID
      syntax_error("Namespace prefix '#{@names[prefix_id]}' cannot be bound to an empty URI")
    end
    if uri_id == @xml_namespace_id || uri_id == @xmlns_namespace_id
      syntax_error("Prefix '#{@names[prefix_id]}' cannot be bound to the reserved namespace '#{@names[uri_id]}'")
    end
    @binding_prefixes << prefix_id
    @binding_uris << uri_id
  end

  # Returns the namespace URI id bound to *prefix_id* (EMPTY_ID for no
  # namespace). Raises when a non-empty prefix is unbound.
  private def resolve_prefix(prefix_id : Int32, name_id : Int32) : Int32
    return @xml_namespace_id if prefix_id == @xml_id
    index = @binding_prefixes.size - 1
    while index >= 0
      return @binding_uris.unsafe_fetch(index) if @binding_prefixes.unsafe_fetch(index) == prefix_id
      index -= 1
    end
    return NameTable::EMPTY_ID if prefix_id == NameTable::EMPTY_ID
    syntax_error("Namespace prefix '#{@names[prefix_id]}' of '#{@names[name_id]}' is not bound")
  end

  # Two prefixed attributes must not share a namespace URI and local name.
  private def check_expanded_attribute_names : Nil
    count = @attrs.size
    outer = 0
    while outer < count
      first = @attrs.unsafe_fetch(outer)
      if first.namespace_uri_id != NameTable::EMPTY_ID && first.namespace_uri_id != @xmlns_namespace_id
        local = @names.local_id(first.name_id)
        inner = outer + 1
        while inner < count
          second = @attrs.unsafe_fetch(inner)
          if second.namespace_uri_id == first.namespace_uri_id && @names.local_id(second.name_id) == local
            syntax_error("Attributes '#{@names[first.name_id]}' and '#{@names[second.name_id]}' have the same expanded name")
          end
          inner += 1
        end
      end
      outer += 1
    end
  end

  private def pop_bindings(binding_mark : Int32) : Nil
    while @binding_prefixes.size > binding_mark
      @binding_prefixes.pop
      @binding_uris.pop
    end
  end

  # Returns the in-scope namespace bindings as prefix id => URI id pairs,
  # innermost last.
  #
  # :nodoc:
  def binding_pairs(from_mark : Int32 = 0) : Array({Int32, Int32})
    Array.new(@binding_prefixes.size - from_mark) do |offset|
      {@binding_prefixes[from_mark + offset], @binding_uris[from_mark + offset]}
    end
  end
end
