require "./node/type"

module Mica::XML
  # A node of a `Mica::XML::Document`: an element, attribute, text, CDATA
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

    private def xml11_document? : Bool
      @document.version == "1.1"
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
        names[@document.split_local_id(record.name_id)]
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
      prefix_id = @document.split_prefix_id(record.name_id)
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
      @document.editing(new_name.bytesize.to_i64) do
        unless element? || attribute? || processing_instruction?
          raise Error.new("Cannot set the name of a #{type} node")
        end
        Escape.check_name(new_name)
        name_id = names.intern(new_name)
        if processing_instruction?
          rename_processing_instruction(new_name, name_id)
          return new_name
        end
        namespace_uri_id = NameTable::EMPTY_ID
        # Namespace rules apply only with namespace processing; otherwise a
        # name is one unit.
        if @document.namespace_aware?
          raise Error.new("Invalid qualified name: #{Core.quote(new_name)}") unless names.qname?(name_id)
          prefix_id = @document.split_prefix_id(name_id)
          if prefix_id == names.intern("xmlns") || new_name == "xmlns"
            raise Error.new("Use []= to declare namespaces, not a rename to #{Core.quote(new_name)}")
          end
          namespace_uri_id = resolve_new_name(new_name, prefix_id)
        end
        check_attribute_rename(new_name, name_id, namespace_uri_id) if attribute?
        @document.rename(@index, name_id, namespace_uri_id)
        new_name
      end
    end

    # Resolves the namespace of a new element or attribute name.
    private def resolve_new_name(new_name : String, prefix_id : Int32) : Int32
      return NameTable::EMPTY_ID if attribute? && prefix_id == NameTable::EMPTY_ID
      scope = element? ? @index : record.parent
      namespace_uri_id = @document.resolve_prefix(scope, prefix_id)
      raise Error.new("Namespace prefix of #{Core.quote(new_name)} is not bound") if namespace_uri_id < 0
      namespace_uri_id
    end

    # An attribute rename must not collide with a sibling attribute.
    private def check_attribute_rename(new_name : String, name_id : Int32, namespace_uri_id : Int32) : Nil
      owner = parent
      return unless owner
      sibling = @document.attribute_named(owner.index, name_id)
      raise Error.new("Attribute #{Core.quote(new_name)} already exists") if sibling && sibling != @index
      return if namespace_uri_id == NameTable::EMPTY_ID
      owner.check_expanded_name_for_rename(namespace_uri_id, @document.split_local_id(name_id), @index)
    end

    # :nodoc:
    def check_expanded_name_for_rename(uri_id : Int32, local_id : Int32, except : Int32) : Nil
      check_unique_expanded_name(uri_id, local_id, except)
    end

    private def rename_processing_instruction(target : String, name_id : Int32) : Nil
      if target.compare("xml", case_insensitive: true) == 0
        raise Error.new("The processing instruction target #{Core.quote(target)} is reserved")
      end
      if @document.namespace_aware? && target.includes?(':')
        raise Error.new("A processing instruction target cannot contain a colon")
      end
      @document.rename(@index, name_id, NameTable::EMPTY_ID)
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

    # :nodoc:
    #
    # Returns the XPath string value: for a text or CDATA node, the text of
    # the whole run of adjacent text and CDATA siblings it starts.
    def xpath_string_value : String
      return content unless text? || cdata?
      String.build do |io|
        current = @index
        while current >= 0
          kind = @document.kind(current)
          break unless kind.text_node? || kind.cdata_section_node?
          io.write(@document.value_bytes(current))
          current = @document.data(current).next_sibling
        end
      end
    end

    # Sets the content. For an element this replaces its children with one
    # text node holding *text* (escaped on output, never parsed as markup).
    def content=(text : String) : String
      @document.editing(text.bytesize.to_i64) do
        Escape.check_text(text, xml11_document?)
        if comment? && (text.includes?("--") || text.ends_with?('-'))
          raise Error.new("A comment cannot contain '--' or end with '-'")
        end
        if processing_instruction? && text.includes?("?>")
          raise Error.new("A processing instruction cannot contain '?>'")
        end
        case type
        when .element_node?
          @document.replace_children_with_text(@index, text)
        when .text_node?, .cdata_section_node?, .comment_node?, .pi_node?, .attribute_node?
          @document.set_value(@index, text)
        else
          raise Error.new("Cannot set the content of a #{type} node")
        end
        text
      end
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
      self[name]? || raise KeyError.new("Missing attribute: #{Core.quote(name)}")
    end

    # Returns the value of attribute *name* (matched by qualified name, then
    # by local name), or nil.
    def []?(name : String) : String?
      attribute = find_attribute(name)
      attribute ? @document.value_string(attribute) : nil
    end

    # Sets attribute *name* to *value*, adding it when missing. A number or
    # Bool is written with `to_s` (at most a few dozen bytes).
    def []=(name : String, value : String | Int::Primitive | Float::Primitive | Bool) : String
      text = value.to_s
      @document.editing(name.bytesize.to_i64 + text.bytesize) do
        raise Error.new("Only elements have attributes") unless element?
        Escape.check_text(text, xml11_document?)
        if attribute = find_exact_attribute(name)
          if @document.kind(attribute).namespace_decl? && !same_value?(attribute, text)
            raise Error.new("Changing the namespace declaration #{Core.quote(name)} is not supported: it would rename nodes in its scope")
          end
          @document.set_value(attribute, text)
          return text
        end
        Escape.check_name(name)
        name_id = names.intern(name)
        unless @document.namespace_aware?
          # Without namespace processing a name is one unit.
          @document.append_attribute(@index, name_id, NameTable::EMPTY_ID, text, Type::ATTRIBUTE_NODE)
          return text
        end
        raise Error.new("Invalid qualified name: #{Core.quote(name)}") unless names.qname?(name_id)
        xmlns_id = names.intern("xmlns")
        if name_id == xmlns_id || @document.split_prefix_id(name_id) == xmlns_id
          add_namespace_declaration(name_id, text)
          return text
        end
        namespace_uri_id = NameTable::EMPTY_ID
        prefix_id = @document.split_prefix_id(name_id)
        unless prefix_id == NameTable::EMPTY_ID
          namespace_uri_id = @document.resolve_prefix(@index, prefix_id)
          raise Error.new("Namespace prefix of #{Core.quote(name)} is not bound") if namespace_uri_id < 0
          check_unique_expanded_name(namespace_uri_id, @document.split_local_id(name_id), -1)
        end
        @document.append_attribute(@index, name_id, namespace_uri_id, text, Type::ATTRIBUTE_NODE)
        text
      end
    end

    # Adds a namespace declaration. It must not change how any existing name
    # in this element's subtree resolves, and must follow Namespaces 1.0.
    private def add_namespace_declaration(name_id : Int32, uri : String) : Nil
      prefix_id = @document.declared_prefix_id(name_id)
      reserved = {Reader::XML_NAMESPACE, Reader::XMLNS_NAMESPACE}
      if prefix_id == NameTable::EMPTY_ID
        raise Error.new("The default namespace cannot be #{Core.quote(uri)}") if reserved.includes?(uri)
      else
        prefix = names[prefix_id]
        raise Error.new("The prefix #{Core.quote(prefix)} cannot be declared") if prefix == "xml" || prefix == "xmlns"
        # Namespaces 1.1 lets an XML 1.1 document undeclare a prefix.
        raise Error.new("A namespace prefix cannot be bound to an empty URI") if uri.empty? && !xml11_document?
        raise Error.new("A prefix cannot be bound to #{Core.quote(uri)}") if reserved.includes?(uri)
      end
      # Restating the binding already in scope renames nothing.
      current = @document.resolve_prefix(@index, prefix_id)
      unless current >= 0 && names.lookup(uri.to_slice) == current
        if subtree_uses_prefix?(prefix_id)
          raise Error.new("Declaring #{Core.quote(names[name_id])} would rename existing nodes in its scope")
        end
      end
      @document.append_attribute(@index, name_id, @document.xmlns_namespace_id, uri, Type::NAMESPACE_DECL)
    end

    # True when an element (or, for a non-empty prefix, an attribute) in this
    # element's subtree is named with *prefix_id* and resolves it through
    # this element. Descendants that redeclare the prefix shadow it, so their
    # subtrees are skipped.
    private def subtree_uses_prefix?(prefix_id : Int32) : Bool
      # No node anywhere is named with the prefix: nothing to inspect.
      return false unless @document.prefix_used?(prefix_id)
      current = @index
      while current >= 0
        # Each node visited, and each attribute examined below, is charged
        # to the edit meter.
        @document.charge_edit(1)
        if @document.kind(current).element_node?
          if current != @index && declares_prefix?(current, prefix_id)
            current = following_outside_subtree(current)
            next
          end
          return true if @document.split_prefix_id(@document.data(current).name_id) == prefix_id
          unless prefix_id == NameTable::EMPTY_ID
            Node.new(@document, current).each_attribute_index do |attribute|
              @document.charge_edit(1)
              return true if @document.split_prefix_id(@document.data(attribute).name_id) == prefix_id
            end
          end
        end
        current = @document.following_in_order(current, @index)
      end
      false
    end

    private def declares_prefix?(element : Int32, prefix_id : Int32) : Bool
      Node.new(@document, element).each_attribute_index(include_declarations: true) do |attribute|
        @document.charge_edit(1)
        record = @document.data(attribute)
        return true if record.kind.namespace_decl? && @document.declared_prefix_id(record.name_id) == prefix_id
      end
      false
    end

    # The next node in document order after the subtree of *index*, staying
    # inside this element's subtree; -1 when there is none.
    private def following_outside_subtree(index : Int32) : Int32
      current = index
      while current != @index && current >= 0
        following = @document.data(current).next_sibling
        return following if following >= 0
        current = @document.data(current).parent
      end
      -1
    end

    # Raises when another attribute of this element has the expanded name
    # {*uri_id*, *local_id*}. *except* is an attribute index to ignore.
    private def check_unique_expanded_name(uri_id : Int32, local_id : Int32, except : Int32) : Nil
      existing = @document.attribute_with_expanded_name(@index, uri_id, local_id)
      return if existing.nil? || existing == except
      raise Error.new("An attribute with the same expanded name already exists")
    end

    # Removes attribute *name* and returns its value, or nil when missing.
    def delete(name : String) : String?
      @document.editing(name.bytesize.to_i64) do
        attribute = find_attribute(name, for_edit: true)
        return unless attribute
        # The removed value is copied out for the caller.
        @document.charge_edit(@document.value_bytes(attribute).size)
        value = @document.value_string(attribute)
        @document.unlink(attribute)
        value
      end
    end

    # True when *attribute*'s value is *text*, compared in place (the old
    # value's bytes are charged first).
    private def same_value?(attribute : Int32, text : String) : Bool
      value = @document.value_bytes(attribute)
      @document.charge_edit(Math.min(value.size, text.bytesize))
      value == text.to_slice
    end

    private def find_exact_attribute(name : String) : Int32?
      return unless element?
      id = names.lookup(name.to_slice)
      return if id < 0
      @document.attribute_named(@index, id)
    end

    # Finds attribute *name* by qualified name, then by local name. Edits
    # (*for_edit*) build the element's attribute index so that a run of
    # deletions stays linear; plain reads use an index only when one
    # exists, so reading never allocates one.
    #
    # Building the index splits every attribute name, so after it a name
    # that was never interned matches nothing. Without an index the local
    # names are compared as bytes: reading never interns, and *name* can
    # be the local part of an attribute name that was never split.
    private def find_attribute(name : String, for_edit : Bool = false) : Int32?
      return unless element?
      @document.index_attributes(@index) if for_edit
      id = names.lookup(name.to_slice)
      if @document.attribute_index?(@index)
        return if id < 0
        exact = @document.attribute_named(@index, id)
        return exact if exact && @document.kind(exact).attribute_node?
        return @document.attribute_with_local_name(@index, id, for_edit)
      end
      if id >= 0
        each_attribute_index do |attribute|
          return attribute if @document.data(attribute).name_id == id
        end
      end
      bytes = name.to_slice
      each_attribute_index do |attribute|
        return attribute if @document.local_name_bytes(@document.data(attribute).name_id) == bytes
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

    # :nodoc:
    #
    # Yields each child, following the sibling links.
    def each_child_node(& : Node ->) : Nil
      child = record.first_child
      while child >= 0
        yield Node.new(@document, child)
        child = @document.data(child).next_sibling
      end
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
    #
    # Raises `Mica::Error` when this node is a namespace declaration that a
    # name in its element's subtree still resolves through.
    def unlink : Nil
      @document.editing(0_i64) do
        check_declaration_unused if @document.kind(@index).namespace_decl?
        @document.unlink(@index)
      end
    end

    private def check_declaration_unused : Nil
      owner = parent
      return unless owner
      prefix_id = @document.declared_prefix_id(@document.data(@index).name_id)
      # A redundant declaration (the enclosing scope binds the same URI) can
      # go without changing how any name resolves.
      inherited = @document.resolve_prefix(@document.data(owner.index).parent, prefix_id)
      uri = @document.value_bytes(@index)
      @document.charge_edit(uri.size)
      return if inherited == names.intern(uri)
      if owner.declaration_in_use?(prefix_id)
        raise Error.new("Removing #{Core.quote(names[@document.data(@index).name_id])} would unbind names in its scope")
      end
    end

    # :nodoc:
    def declaration_in_use?(prefix_id : Int32) : Bool
      subtree_uses_prefix?(prefix_id)
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
      io << "#<Mica::XML::Node " << type
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
    # The evaluation runs under *budget*, or draws on *meter* when given
    # (see `XPath::Expression#evaluate`).
    #
    # Raises `Mica::XML::XPathError` on a syntax error or an unsupported
    # feature, and `Mica::LimitExceededError` when the budget or deadline
    # runs out.
    def xpath(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil,
              *, budget : Core::WorkBudget = XPath::DEFAULT_WORK_BUDGET, meter : Core::WorkMeter? = nil) : XPath::Value
      work_meter = meter || Core::WorkMeter.new(budget)
      XPath.compile(path, work_meter).evaluate(self, namespaces, variables, meter: work_meter)
    end

    # Evaluates *path* and returns the resulting node set. Raises
    # `Mica::XML::XPathError` when the result is not a node set.
    def xpath_nodes(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil,
                    *, budget : Core::WorkBudget = XPath::DEFAULT_WORK_BUDGET, meter : Core::WorkMeter? = nil) : NodeSet
      result = xpath(path, namespaces, variables, budget: budget, meter: meter)
      result.as?(NodeSet) || raise XPathError.new("XPath #{Core.quote(path)} returned #{result.class}, not a node set")
    end

    # Evaluates *path* and returns the first node, or nil.
    def xpath_node(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil,
                   *, budget : Core::WorkBudget = XPath::DEFAULT_WORK_BUDGET, meter : Core::WorkMeter? = nil) : Node?
      xpath_nodes(path, namespaces, variables, budget: budget, meter: meter).first?
    end

    # Evaluates *path* and converts the result to a string (XPath `string()`
    # rules: a node set gives its first node's string value).
    def xpath_string(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil,
                     *, budget : Core::WorkBudget = XPath::DEFAULT_WORK_BUDGET, meter : Core::WorkMeter? = nil) : String
      work_meter = meter || Core::WorkMeter.new(budget)
      XPath.compile(path, work_meter).evaluate_string(self, namespaces, variables, meter: work_meter)
    end

    # Evaluates *path* and converts the result to a number.
    def xpath_float(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil,
                    *, budget : Core::WorkBudget = XPath::DEFAULT_WORK_BUDGET, meter : Core::WorkMeter? = nil) : Float64
      work_meter = meter || Core::WorkMeter.new(budget)
      XPath.compile(path, work_meter).evaluate_number(self, namespaces, variables, meter: work_meter)
    end

    # Evaluates *path* and converts the result to a boolean.
    def xpath_bool(path : String, namespaces : Hash(String, String)? = nil, variables : Hash(String, XPath::Value)? = nil,
                   *, budget : Core::WorkBudget = XPath::DEFAULT_WORK_BUDGET, meter : Core::WorkMeter? = nil) : Bool
      work_meter = meter || Core::WorkMeter.new(budget)
      XPath.compile(path, work_meter).evaluate_boolean(self, namespaces, variables, meter: work_meter)
    end
  end
end
