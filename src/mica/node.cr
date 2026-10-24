require "./node/type"

module Mica
  # A node of a `Mica::Document`: an element, attribute, text, CDATA
  # section, comment, processing instruction, DOCTYPE, entity reference or
  # the document itself.
  #
  # `Node` is a struct holding its document and an index, so it is cheap to
  # pass around and two `Node` values for the same node compare equal. The
  # API mirrors stdlib `XML::Node`.
  struct Node
    # Returns the document this node belongs to.
    getter document : Document

    # :nodoc:
    getter index : Int32

    # :nodoc:
    def initialize(@document : Document, @index : Int32)
    end

    def ==(other : Node) : Bool
      @document.same?(other.document) && @index == other.index
    end

    def hash(hasher)
      hasher = @document.object_id.hash(hasher)
      @index.hash(hasher)
    end

    # Returns the node's type.
    def type : Type
      @document.kind(@index)
    end

    def element? : Bool
      type.element_node?
    end

    def attribute? : Bool
      type.attribute_node?
    end

    def text? : Bool
      type.text_node?
    end

    def cdata? : Bool
      type.cdata_section_node?
    end

    def comment? : Bool
      type.comment_node?
    end

    def processing_instruction? : Bool
      type.pi_node?
    end

    def entity_reference? : Bool
      type.entity_ref_node?
    end

    def dtd? : Bool
      type.dtd_node?
    end

    # Returns true for the document node.
    def document? : Bool
      type.document_node?
    end

    # Same as `document?` (stdlib name).
    def xml? : Bool
      document?
    end

    # Always false: Mica has no document fragments.
    def fragment? : Bool
      false
    end

    private def record : Document::NodeData
      @document.data(@index)
    end

    private def names : NameTable
      @document.names
    end

    # Returns the node's name: the local name for elements and attributes
    # (as in stdlib), the target for PIs, the name for entity references and
    # the DOCTYPE; `"text"`, `"#cdata-section"`, `"comment"` or
    # `"document"` otherwise.
    def name : String
      case type
      when .element_node?, .attribute_node?, .namespace_decl?
        names[names.local_id(record.name_id)]
      when .pi_node?, .entity_ref_node?, .dtd_node?
        names[record.name_id]
      when .text_node?
        "text"
      when .cdata_section_node?
        "#cdata-section"
      when .comment_node?
        "comment"
      when .document_node?
        "document"
      else
        ""
      end
    end

    # Returns the qualified name (`prefix:local`) of an element or
    # attribute; the same as `name` for other nodes.
    def qualified_name : String
      case type
      when .element_node?, .attribute_node?, .namespace_decl?
        names[record.name_id]
      else
        name
      end
    end

    # Returns the namespace prefix of an element or attribute, or nil.
    def prefix : String?
      return unless element? || attribute?
      prefix_id = names.prefix_id(record.name_id)
      prefix_id == NameTable::EMPTY_ID ? nil : names[prefix_id]
    end

    # Returns the namespace URI of an element or attribute, or nil.
    def namespace_uri : String?
      return unless element? || attribute?
      uri_id = record.namespace_uri_id
      uri_id == NameTable::EMPTY_ID ? nil : names[uri_id]
    end

    # Returns the namespace of an element or attribute, or nil when it is in
    # no namespace.
    def namespace : Namespace?
      if uri = namespace_uri
        Namespace.new(@document, prefix, uri)
      end
    end

    # Renames an element, attribute or PI. A prefixed name is resolved
    # against the namespace declarations in scope.
    #
    # Raises `Mica::Error` for an invalid name or an unbound prefix.
    def name=(new_name : String) : String
      unless element? || attribute? || processing_instruction?
        raise Error.new("Cannot set the name of a #{type} node")
      end
      Escape.check_name(new_name)
      name_id = names.intern(new_name)
      namespace_uri_id = NameTable::EMPTY_ID
      if element? || attribute?
        raise Error.new("Invalid qualified name: #{new_name.inspect}") unless names.qname?(name_id)
        prefix_id = names.prefix_id(name_id)
        if element? || prefix_id != NameTable::EMPTY_ID
          scope = element? ? @index : record.parent
          namespace_uri_id = @document.resolve_prefix(scope, prefix_id)
          raise Error.new("Namespace prefix of #{new_name.inspect} is not bound") if namespace_uri_id < 0
        end
      end
      @document.rename(@index, name_id, namespace_uri_id)
      new_name
    end

    # Returns the text content: the concatenated text of all descendant text
    # and CDATA nodes for elements and the document; the value for other
    # nodes.
    def content : String
      case type
      when .element_node?, .document_node?
        String.build { |io| each_text_in_subtree { |bytes| io.write(bytes) } }
      when .entity_ref_node?, .dtd_node?
        ""
      else
        @document.value_string(@index)
      end
    end

    # :nodoc:
    #
    # Yields the bytes of every text and CDATA node under this node, in
    # document order.
    def each_text_in_subtree(&) : Nil
      if @document.index_order?
        stop = @document.subtree_end(@index)
        current = @index + 1
        while current < stop
          kind = @document.kind(current)
          yield @document.value_bytes(current) if kind.text_node? || kind.cdata_section_node?
          current += 1
        end
      else
        current = @document.following_in_order(@index, @index)
        while current >= 0
          kind = @document.kind(current)
          yield @document.value_bytes(current) if kind.text_node? || kind.cdata_section_node?
          current = @document.following_in_order(current, @index)
        end
      end
    end

    # Sets the content. For an element this replaces its children with one
    # text node holding *text* (escaped on output, never parsed as markup).
    def content=(text : String) : String
      Escape.check_text(text)
      if comment? && (text.includes?("--") || text.ends_with?('-'))
        raise Error.new("A comment cannot contain '--' or end with '-'")
      end
      if processing_instruction? && text.includes?("?>")
        raise Error.new("A processing instruction cannot contain '?>'")
      end
      case type
      when .element_node?
        @document.replace_children_with_text(@index, text)
      when .text_node?, .cdata_section_node?, .comment_node?, .pi_node?, .attribute_node?, .namespace_decl?
        @document.set_value(@index, text)
      else
        raise Error.new("Cannot set the content of a #{type} node")
      end
      text
    end

    # Same as `content`.
    def text : String
      content
    end

    # Same as `content=`.
    def text=(text : String) : String
      self.content = text
    end

    # Same as `content`.
    def inner_text : String
      content
    end

    # Returns the value of attribute *name*. Raises `KeyError` when missing.
    def [](name : String) : String
      self[name]? || raise KeyError.new("Missing attribute: #{name}")
    end

    # Returns the value of attribute *name* (matched by qualified name, then
    # by local name), or nil.
    def []?(name : String) : String?
      attribute = find_attribute(name)
      attribute ? @document.value_string(attribute) : nil
    end

    # Sets attribute *name* to *value*, adding it when missing.
    def []=(name : String, value) : String
      raise Error.new("Only elements have attributes") unless element?
      text = value.to_s
      Escape.check_text(text)
      if attribute = find_exact_attribute(name)
        @document.set_value(attribute, text)
        return text
      end
      Escape.check_name(name)
      name_id = names.intern(name)
      raise Error.new("Invalid qualified name: #{name.inspect}") unless names.qname?(name_id)
      xmlns_id = names.intern("xmlns")
      if name_id == xmlns_id || names.prefix_id(name_id) == xmlns_id
        @document.append_attribute(@index, name_id, @document.xmlns_namespace_id, text, Type::NAMESPACE_DECL)
        return text
      end
      namespace_uri_id = NameTable::EMPTY_ID
      prefix_id = names.prefix_id(name_id)
      unless prefix_id == NameTable::EMPTY_ID
        namespace_uri_id = @document.resolve_prefix(@index, prefix_id)
        raise Error.new("Namespace prefix of #{name.inspect} is not bound") if namespace_uri_id < 0
      end
      @document.append_attribute(@index, name_id, namespace_uri_id, text, Type::ATTRIBUTE_NODE)
      text
    end

    # Removes attribute *name* and returns its value, or nil when missing.
    def delete(name : String) : String?
      attribute = find_attribute(name)
      return unless attribute
      value = @document.value_string(attribute)
      @document.unlink(attribute)
      value
    end

    private def find_exact_attribute(name : String) : Int32?
      return unless element?
      id = names.lookup(name.to_slice)
      return if id < 0
      each_attribute_index(include_declarations: true) do |attribute|
        return attribute if @document.data(attribute).name_id == id
      end
      nil
    end

    private def find_attribute(name : String) : Int32?
      return unless element?
      id = names.lookup(name.to_slice)
      return if id < 0
      each_attribute_index do |attribute|
        return attribute if @document.data(attribute).name_id == id
      end
      each_attribute_index do |attribute|
        return attribute if names.local_id(@document.data(attribute).name_id) == id
      end
      nil
    end

    # :nodoc:
    def each_attribute_index(include_declarations : Bool = false, &) : Nil
      return unless element?
      attribute = record.first_attribute
      while attribute >= 0
        attribute_record = @document.data(attribute)
        yield attribute if attribute_record.kind.attribute_node? || include_declarations
        attribute = attribute_record.next_sibling
      end
    end

    # Returns the element's attributes (namespace declarations excluded).
    def attributes : Attributes
      Attributes.new(self)
    end

    # Returns the child nodes.
    def children : NodeSet
      nodes = [] of Node
      child = record.first_child
      while child >= 0
        nodes << Node.new(@document, child)
        child = @document.data(child).next_sibling
      end
      NodeSet.new(nodes)
    end

    # Returns the first child that is an element, or nil.
    def first_element_child : Node?
      child = record.first_child
      while child >= 0
        return Node.new(@document, child) if @document.kind(child).element_node?
        child = @document.data(child).next_sibling
      end
      nil
    end

    # Returns the parent node (the owning element for attributes), or nil
    # for the document and for unlinked nodes.
    def parent : Node?
      parent = record.parent
      parent >= 0 ? Node.new(@document, parent) : nil
    end

    # Returns the next sibling, or nil.
    def next : Node?
      following = record.next_sibling
      following >= 0 ? Node.new(@document, following) : nil
    end

    # :ditto:
    def next_sibling : Node?
      self.next
    end

    # Returns the previous sibling, or nil.
    def previous : Node?
      previous = record.previous_sibling
      previous >= 0 ? Node.new(@document, previous) : nil
    end

    # :ditto:
    def previous_sibling : Node?
      previous
    end

    # Returns the next sibling that is an element, or nil.
    def next_element : Node?
      following = record.next_sibling
      while following >= 0
        return Node.new(@document, following) if @document.kind(following).element_node?
        following = @document.data(following).next_sibling
      end
      nil
    end

    # Returns the previous sibling that is an element, or nil.
    def previous_element : Node?
      previous = record.previous_sibling
      while previous >= 0
        return Node.new(@document, previous) if @document.kind(previous).element_node?
        previous = @document.data(previous).previous_sibling
      end
      nil
    end

    # Returns the document's root element, or nil.
    def root : Node?
      @document.node_at(0).first_element_child
    end

    # Returns the namespaces declared on this element.
    def namespace_definitions : Array(Namespace)
      definitions = [] of Namespace
      each_attribute_index(include_declarations: true) do |attribute|
        declaration = @document.data(attribute)
        next unless declaration.kind.namespace_decl?
        prefix_id = @document.declared_prefix_id(declaration.name_id)
        prefix = prefix_id == NameTable::EMPTY_ID ? nil : names[prefix_id]
        definitions << Namespace.new(@document, prefix, @document.value_string(attribute))
      end
      definitions
    end

    # Returns the namespaces in scope on this node: its own declarations and
    # its ancestors', the innermost declaration of each prefix winning.
    def namespace_scopes : Array(Namespace)
      seen = Set(String?).new
      scopes = [] of Namespace
      current = element? ? self : parent
      while current
        current.namespace_definitions.each do |definition|
          scopes << definition if seen.add?(definition.prefix)
        end
        current = current.parent
      end
      scopes
    end

    # Returns the namespaces in scope as `"xmlns:prefix" => uri` (and
    # `"xmlns" => uri` for the default namespace), like stdlib.
    def namespaces : Hash(String, String?)
      result = {} of String => String?
      namespace_scopes.each do |scope|
        key = (prefix = scope.prefix) ? "xmlns:#{prefix}" : "xmlns"
        result[key] = scope.href
      end
      result
    end

    # Detaches this node (and its subtree) from the document tree. The node
    # stays usable on its own.
    def unlink : Nil
      @document.unlink(@index)
    end

    def to_s(io : IO) : Nil
      to_xml(io)
    end

    # Serializes this node as XML. With *indent* above 0, elements whose
    # children are all elements, comments or PIs are indented (mixed
    # content is written as is, like libxml2's format mode).
    def to_xml(indent : Int = 2, indent_text : String = " ") : String
      String.build { |io| to_xml(io, indent, indent_text) }
    end

    # :ditto:
    def to_xml(io : IO, indent : Int = 2, indent_text : String = " ") : Nil
      Serializer.new(io, indent.to_i32, indent_text).write(self)
    end

    def inspect(io : IO) : Nil
      io << "#<Mica::Node " << type
      if element? || attribute? || processing_instruction?
        io << " name="
        qualified_name.inspect(io)
      end
      if text? || cdata? || comment? || attribute?
        io << " content="
        content.inspect(io)
      end
      io << '>'
    end

    # Evaluates XPath *path* with this node as the context node. Returns a
    # `NodeSet`, `String`, `Float64` or `Bool`.
    #
    # *namespaces* maps prefixes to URIs. Without it, the namespaces declared
    # on the root element are registered (the default namespace under the
    # prefix `xmlns`), like stdlib. *variables* binds `$name` references.
    #
    # Raises `Mica::XPathError` on a syntax error or an unsupported feature.
    def xpath(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil) : XPath::Value
      XPath.compile(path).evaluate(self, namespaces, variables)
    end

    # Evaluates *path* and returns the resulting node set. Raises
    # `Mica::XPathError` when the result is not a node set.
    def xpath_nodes(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil) : NodeSet
      result = xpath(path, namespaces, variables)
      result.as?(NodeSet) || raise XPathError.new("XPath #{path.inspect} returned #{result.class}, not a node set")
    end

    # Evaluates *path* and returns the first node, or nil.
    def xpath_node(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil) : Node?
      xpath_nodes(path, namespaces, variables).first?
    end

    # Evaluates *path* and converts the result to a string (XPath `string()`
    # rules: a node set gives its first node's string value).
    def xpath_string(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil) : String
      XPath.to_xpath_string(xpath(path, namespaces, variables))
    end

    # Evaluates *path* and converts the result to a number.
    def xpath_float(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil) : Float64
      XPath.to_xpath_number(xpath(path, namespaces, variables))
    end

    # Evaluates *path* and converts the result to a boolean.
    def xpath_bool(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil) : Bool
      XPath.to_xpath_boolean(xpath(path, namespaces, variables))
    end
  end
end
