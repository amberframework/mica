class Mica::XML::Reader
  # Applies Namespaces in XML 1.0 (and, in XML 1.1 documents, Namespaces
  # 1.1, which lets `xmlns:p=""` undeclare a prefix) to the current start
  # tag, after DTD
  # defaults were added: binds the tag's declarations, then resolves the
  # element and attribute prefixes, then checks expanded attribute names for
  # duplicates. Returns the binding stack size before this tag's bindings.
  private def process_namespaces(element_id : Int32) : Int32
    binding_mark = @binding_prefixes.size
    count = @attrs.size
    charge_in_token(count)
    index = 0
    while index < count
      slot = @attrs[index]
      attr_id = slot.name_id
      unless @names.qname?(attr_id)
        syntax_error("Attribute name '#{Core.excerpt(@names[attr_id])}' is not a valid QName")
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
      syntax_error("Element name '#{Core.excerpt(@names[element_id])}' is not a valid QName")
    end
    element_prefix = @names.prefix_id(element_id)
    if element_prefix == @xmlns_id
      syntax_error("Element name '#{Core.excerpt(@names[element_id])}' must not use the xmlns prefix")
    end
    @namespace_uri_id = resolve_prefix(element_prefix, element_id)

    prefixed = 0
    index = 0
    while index < count
      slot = @attrs[index]
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
    uri_id = intern_namespace_uri(slot)
    if uri_id == @xml_namespace_id || uri_id == @xmlns_namespace_id
      syntax_error("The default namespace cannot be '#{Core.excerpt(@names[uri_id])}'")
    end
    push_binding(NameTable::EMPTY_ID, uri_id)
  end

  private def bind_prefix(slot : AttributeSlot) : Nil
    prefix_id = @names.local_id(slot.name_id)
    uri_id = intern_namespace_uri(slot)
    if prefix_id == @xml_id
      unless uri_id == @xml_namespace_id
        syntax_error("The xml prefix must be bound to #{XML_NAMESPACE}")
      end
      return
    end
    if prefix_id == @xmlns_id
      syntax_error("The xmlns prefix must not be declared")
    end
    if uri_id == NameTable::EMPTY_ID && !@xml11
      syntax_error("Namespace prefix '#{Core.excerpt(@names[prefix_id])}' cannot be bound to an empty URI")
    end
    if uri_id == @xml_namespace_id || uri_id == @xmlns_namespace_id
      syntax_error("Prefix '#{Core.excerpt(@names[prefix_id])}' cannot be bound to the reserved namespace '#{Core.excerpt(@names[uri_id])}'")
    end
    # In XML 1.1 documents (Namespaces 1.1), `xmlns:p=""` undeclares p.
    push_binding(prefix_id, uri_id)
  end

  # Interns a declaration's URI. Hashing and storing it pass over its bytes,
  # which can be long: charged before interning (the table's own count of
  # the same work is charged again later, an overcharge kept for order).
  private def intern_namespace_uri(slot : AttributeSlot) : Int32
    value = attribute_value_bytes(slot)
    charge(2 * value.size)
    @names.intern(value)
  end

  # Pushes a binding and links it to the previous binding of the same
  # prefix, so lookup and pop are O(1).
  private def push_binding(prefix_id : Int32, uri_id : Int32) : Nil
    while @innermost_binding.size <= prefix_id
      @innermost_binding << -1
    end
    charge_in_token(1)
    @binding_previous << @innermost_binding[prefix_id]
    @innermost_binding[prefix_id] = @binding_prefixes.size
    @binding_prefixes << prefix_id
    @binding_uris << uri_id
  end

  # Returns the namespace URI id bound to *prefix_id* (EMPTY_ID for no
  # namespace). Raises when a non-empty prefix is unbound (or undeclared).
  @[AlwaysInline]
  private def resolve_prefix(prefix_id : Int32, name_id : Int32) : Int32
    return @xml_namespace_id if prefix_id == @xml_id
    charge_in_token(1)
    binding = prefix_id < @innermost_binding.size ? @innermost_binding[prefix_id] : -1
    uri_id = binding >= 0 ? @binding_uris[binding] : NameTable::EMPTY_ID
    return uri_id if uri_id != NameTable::EMPTY_ID || prefix_id == NameTable::EMPTY_ID
    syntax_error("Namespace prefix '#{Core.excerpt(@names[prefix_id])}' of '#{Core.excerpt(@names[name_id])}' is not bound")
  end

  # Two prefixed attributes must not share a namespace URI and local name.
  private def check_expanded_attribute_names : Nil
    seen = Set({Int32, Int32}).new
    charge_in_token(@attrs.size)
    @attrs.each do |slot|
      uri_id = slot.namespace_uri_id
      next if uri_id == NameTable::EMPTY_ID || uri_id == @xmlns_namespace_id
      unless seen.add?({uri_id, @names.local_id(slot.name_id)})
        syntax_error("Attribute '#{Core.excerpt(@names[slot.name_id])}' duplicates the expanded name of another attribute")
      end
    end
  end

  # Charged before popping, so a wide element's bindings cannot be undone
  # past an exhausted budget.
  private def pop_bindings(binding_mark : Int32) : Nil
    charge((@binding_prefixes.size - binding_mark).to_i64) if @binding_prefixes.size > binding_mark
    while @binding_prefixes.size > binding_mark
      prefix_id = @binding_prefixes.pop
      @binding_uris.pop
      @innermost_binding[prefix_id] = @binding_previous.pop
    end
  end
end
