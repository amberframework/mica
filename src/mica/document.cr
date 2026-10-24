module Mica
  # A parsed XML document.
  #
  # Nodes live in an arena owned by the document: fixed-size records in
  # pages plus a chunked heap for names' values and text. `Mica::Node` is a
  # small struct (document + index) pointing into it, so a large document
  # costs a few allocations instead of one object per node, and the garbage
  # collector never scans node records (they hold no pointers).
  #
  # A document answers the `Mica::Node` API for its document node:
  #
  # ```
  # document = Mica.parse(%(<feed><title>News</title></feed>))
  # document.root.try(&.name)                # => "feed"
  # document.xpath_string("string(//title)") # => "News"
  # ```
  class Document
    # :nodoc:
    #
    # One node record. Ints only, so pages are allocated atomic.
    struct NodeData
      property kind : Node::Type
      property parent : Int32 = -1
      property first_child : Int32 = -1
      property last_child : Int32 = -1
      property previous_sibling : Int32 = -1
      property next_sibling : Int32 = -1
      property first_attribute : Int32 = -1
      property name_id : Int32 = 0
      property namespace_uri_id : Int32 = 0
      property value_ref : Int32 = 0
      property value_size : Int32 = 0

      def initialize(@kind : Node::Type)
      end
    end

    private PAGE_BITS   = 12
    private PAGE_SIZE   = 1 << PAGE_BITS
    private PAGE_MASK   = PAGE_SIZE - 1
    private CHUNK_BITS  = 18
    private CHUNK_SIZE  = 1 << CHUNK_BITS
    private CHUNK_MASK  = CHUNK_SIZE - 1
    private LARGE_VALUE = 16 * 1024
    private MAX_CHUNKS  = Int32::MAX // CHUNK_SIZE

    # :nodoc:
    getter names : NameTable

    # Returns the XML version from the declaration (`"1.0"` when absent).
    getter version : String = "1.0"

    # Returns the encoding the document was read from.
    getter encoding : String? = nil

    # Returns true when the declaration says `standalone="yes"`.
    getter? standalone : Bool = false

    # Returns the DOCTYPE public identifier, if any.
    getter public_id : String? = nil

    # Returns the DOCTYPE system identifier, if any. It was never fetched.
    getter system_id : String? = nil

    # Returns the raw internal DTD subset, if any.
    getter internal_subset : String? = nil

    # :nodoc:
    #
    # Declarations read from the internal subset.
    getter dtd : DTD = DTD.new

    @pages = [] of Pointer(NodeData)
    @size = 0
    @chunks = [] of Bytes
    @chunk_used = CHUNK_SIZE
    @large_values = [] of Bytes
    @order_keys : Array(Int32)? = nil
    @merging_text_node = -1
    @text_merge_buffer = IO::Memory.new
    @order_dirty = false
    @xmlns_namespace_id : Int32
    @xml_namespace_id : Int32
    @xml_prefix_id : Int32
    @xmlns_id : Int32

    # True when the document was parsed with Namespaces in XML enforced
    # (`ParserOptions#namespace_aware`). Edits follow the same rules.
    property? namespace_aware : Bool = true

    # :nodoc:
    def initialize(@names : NameTable = NameTable.new)
      @xmlns_namespace_id = @names.intern(Reader::XMLNS_NAMESPACE)
      @xml_namespace_id = @names.intern(Reader::XML_NAMESPACE)
      @xml_prefix_id = @names.intern("xml")
      @xmlns_id = @names.intern("xmlns")
      add_node(Node::Type::DOCUMENT_NODE, -1, 0, 0, Bytes.empty)
    end

    # Parses *source* into a document. See `Mica.parse`.
    def self.parse(source : String | Bytes | IO, options : ParserOptions = ParserOptions.default) : Document
      reader = Reader.new(source, options)
      document = new(reader.names)
      document.build_from(reader)
      document
    end

    # Returns the document node.
    def node : Node
      Node.new(self, 0)
    end

    delegate :root, :children, :first_element_child, :content, :text, :inner_text,
      :to_xml, :xpath, :xpath_nodes, :xpath_node, :xpath_string, :xpath_bool,
      :xpath_float, :type, :name, :document?, :xml?, to: node

    def to_s(io : IO) : Nil
      node.to_s(io)
    end

    def inspect(io : IO) : Nil
      node.inspect(io)
    end

    # Returns the number of node records, including attributes and unlinked
    # nodes.
    def node_count : Int32
      @size
    end

    # :nodoc:
    def build_from(reader : Reader) : Nil
      @namespace_aware = reader.options.namespace_aware?
      parent = 0
      while reader.read
        parent = add_event(reader, parent)
      end
      finish_text_merge
      copy_prolog(reader)
    end

    # :nodoc:
    #
    # Builds the subtree of the element the reader is on, then leaves the
    # reader on that element's end.
    def build_subtree_from(reader : Reader) : Nil
      @namespace_aware = reader.options.namespace_aware?
      copy_prolog(reader)
      depth = reader.event_depth
      name_id = reader.event_name_id
      namespace_uri_id = reader.event_namespace_uri_id
      element = add_element(reader, 0)
      unless reader.empty_element?
        parent = element
        while reader.read
          break if reader.event_type.end_element? && reader.event_depth == depth
          parent = add_event(reader, parent)
        end
        finish_text_merge
      end
      reader.finish_expand(name_id, namespace_uri_id, depth)
    end

    private def copy_prolog(reader : Reader) : Nil
      @version = reader.xml_version
      @encoding = reader.encoding
      @standalone = reader.standalone?
      @public_id = reader.public_id
      @system_id = reader.system_id
      @internal_subset = reader.internal_subset
      @dtd = reader.dtd
    end

    private def add_event(reader : Reader, parent : Int32) : Int32
      type = reader.event_type
      finish_text_merge_before(type)
      case type
      when .element?
        element = add_element(reader, parent)
        return element unless reader.empty_element?
      when .end_element?
        return data(parent).parent
      when .text?, .significant_whitespace?
        add_text(parent, reader.value_bytes)
      when .cdata?
        append_new(Node::Type::CDATA_SECTION_NODE, parent, 0, 0, reader.value_bytes)
      when .comment?
        append_new(Node::Type::COMMENT_NODE, parent, 0, 0, reader.value_bytes)
      when .processing_instruction?
        append_new(Node::Type::PI_NODE, parent, reader.event_name_id, 0, reader.value_bytes)
      when .document_type?
        append_new(Node::Type::DTD_NODE, parent, reader.event_name_id, 0, Bytes.empty)
      when .entity_reference?
        append_new(Node::Type::ENTITY_REF_NODE, parent, reader.event_name_id, 0, Bytes.empty)
      end
      parent
    end

    private def add_element(reader : Reader, parent : Int32) : Int32
      element = append_new(Node::Type::ELEMENT_NODE, parent, reader.event_name_id, reader.event_namespace_uri_id, Bytes.empty)
      previous = -1
      reader.event_attributes.each do |slot|
        kind = slot.namespace_uri_id == @xmlns_namespace_id ? Node::Type::NAMESPACE_DECL : Node::Type::ATTRIBUTE_NODE
        attribute = add_node(kind, element, slot.name_id, slot.namespace_uri_id, reader.attribute_value_bytes(slot))
        link_attribute(element, attribute, previous)
        previous = attribute
      end
      element
    end

    # Adds text under *parent*. Adjacent text events (around entity
    # boundaries) merge into one node; the merged text is collected in a
    # buffer and stored once, so merging stays linear.
    private def add_text(parent : Int32, bytes : Bytes) : Nil
      last = data(parent).last_child
      if last >= 0 && data(last).kind.text_node?
        if @merging_text_node != last
          @text_merge_buffer.clear
          @text_merge_buffer.write(value_bytes(last))
          @merging_text_node = last
        end
        @text_merge_buffer.write(bytes)
        return
      end
      append_new(Node::Type::TEXT_NODE, parent, 0, 0, bytes)
    end

    private def finish_text_merge_before(type : Reader::Type) : Nil
      return if @merging_text_node < 0
      finish_text_merge unless type.text? || type.significant_whitespace?
    end

    private def finish_text_merge : Nil
      node = @merging_text_node
      return if node < 0
      store_value(node, @text_merge_buffer.to_slice)
      @merging_text_node = -1
      @text_merge_buffer.clear
    end

    # :nodoc:
    @[AlwaysInline]
    def data(index : Int32) : NodeData
      @pages.unsafe_fetch(index >> PAGE_BITS)[index & PAGE_MASK]
    end

    @[AlwaysInline]
    private def data_pointer(index : Int32) : Pointer(NodeData)
      @pages.unsafe_fetch(index >> PAGE_BITS) + (index & PAGE_MASK)
    end

    # :nodoc:
    def kind(index : Int32) : Node::Type
      data(index).kind
    end

    # :nodoc:
    def node_at(index : Int32) : Node
      Node.new(self, index)
    end

    # :nodoc:
    def value_bytes(index : Int32) : Bytes
      record = data(index)
      size = record.value_size
      return Bytes.empty if size == 0
      ref = record.value_ref
      if ref < 0
        @large_values.unsafe_fetch(-ref - 1)
      else
        @chunks.unsafe_fetch(ref >> CHUNK_BITS)[ref & CHUNK_MASK, size]
      end
    end

    # :nodoc:
    def value_string(index : Int32) : String
      String.new(value_bytes(index))
    end

    private def add_node(kind : Node::Type, parent : Int32, name_id : Int32, namespace_uri_id : Int32, value : Bytes) : Int32
      index = @size
      if index & PAGE_MASK == 0
        if index == Int32::MAX & ~PAGE_MASK
          raise Error.new("Document exceeds the maximum node count")
        end
        @pages << Pointer(NodeData).malloc(PAGE_SIZE)
      end
      @size += 1
      record = NodeData.new(kind)
      record.parent = parent
      record.name_id = name_id
      record.namespace_uri_id = namespace_uri_id
      data_pointer(index).value = record
      store_value(index, value) unless value.empty?
      index
    end

    private def append_new(kind : Node::Type, parent : Int32, name_id : Int32, namespace_uri_id : Int32, value : Bytes) : Int32
      index = add_node(kind, parent, name_id, namespace_uri_id, value)
      link_child(parent, index)
      index
    end

    # :nodoc:
    #
    # Copies *value* into the heap and points node *index* at it.
    def store_value(index : Int32, value : Bytes) : Nil
      ref = 0
      size = value.size
      if size > LARGE_VALUE
        @large_values << value.dup
        ref = -@large_values.size
      elsif size > 0
        if @chunk_used + size > CHUNK_SIZE
          raise Error.new("Document text exceeds 2 GiB") if @chunks.size >= MAX_CHUNKS
          @chunks << Bytes.new(CHUNK_SIZE)
          @chunk_used = 0
        end
        chunk = @chunks.last
        (chunk.to_unsafe + @chunk_used).copy_from(value.to_unsafe, size)
        ref = ((@chunks.size - 1) << CHUNK_BITS) + @chunk_used
        @chunk_used += size
      end
      pointer = data_pointer(index)
      record = pointer.value
      record.value_ref = ref
      record.value_size = size
      pointer.value = record
    end

    private def link_child(parent : Int32, child : Int32) : Nil
      parent_pointer = data_pointer(parent)
      parent_record = parent_pointer.value
      last = parent_record.last_child
      if last < 0
        parent_record.first_child = child
      else
        update(last) { |record| record.next_sibling = child; record }
        update(child) { |record| record.previous_sibling = last; record }
      end
      parent_record.last_child = child
      parent_pointer.value = parent_record
      update(child) { |record| record.parent = parent; record }
    end

    private def link_attribute(element : Int32, attribute : Int32, previous : Int32) : Nil
      if previous < 0
        update(element) { |record| record.first_attribute = attribute; record }
      else
        update(previous) { |record| record.next_sibling = attribute; record }
        update(attribute) { |record| record.previous_sibling = previous; record }
      end
    end

    # Applies a change to the record of node *index*.
    @[AlwaysInline]
    private def update(index : Int32, & : NodeData -> NodeData) : Nil
      pointer = data_pointer(index)
      record = pointer.value
      pointer.value = yield record
    end

    # --- Mutation (used by Mica::Node) -------------------------------------

    # :nodoc:
    def set_value(index : Int32, value : String) : Nil
      store_value(index, value.to_slice)
    end

    # :nodoc:
    #
    # Detaches node *index* from its parent (or element, for attributes).
    def unlink(index : Int32) : Nil
      record = data(index)
      parent = record.parent
      return if parent < 0
      previous = record.previous_sibling
      following = record.next_sibling
      attribute = record.kind.attribute_node? || record.kind.namespace_decl?
      if previous >= 0
        update(previous) { |sibling| sibling.next_sibling = following; sibling }
      elsif attribute
        update(parent) { |owner| owner.first_attribute = following; owner }
      else
        update(parent) { |owner| owner.first_child = following; owner }
      end
      if following >= 0
        update(following) { |sibling| sibling.previous_sibling = previous; sibling }
      elsif !attribute
        update(parent) { |owner| owner.last_child = previous; owner }
      end
      update(index) do |detached|
        detached.parent = -1
        detached.previous_sibling = -1
        detached.next_sibling = -1
        detached
      end
      mark_order_dirty
    end

    # :nodoc:
    #
    # Replaces the children of *index* with one text node holding *text*.
    def replace_children_with_text(index : Int32, text : String) : Nil
      child = data(index).first_child
      while child >= 0
        following = data(child).next_sibling
        unlink(child)
        child = following
      end
      append_new(Node::Type::TEXT_NODE, index, 0, 0, text.to_slice) unless text.empty?
      mark_order_dirty
    end

    # :nodoc:
    #
    # Adds an attribute (or namespace declaration) at the end of the
    # element's attribute list.
    def append_attribute(element : Int32, name_id : Int32, namespace_uri_id : Int32, value : String, kind : Node::Type) : Int32
      attribute = add_node(kind, element, name_id, namespace_uri_id, value.to_slice)
      last = -1
      current = data(element).first_attribute
      while current >= 0
        last = current
        current = data(current).next_sibling
      end
      link_attribute(element, attribute, last)
      mark_order_dirty
      attribute
    end

    # :nodoc:
    def rename(index : Int32, name_id : Int32, namespace_uri_id : Int32) : Nil
      update(index) do |record|
        record.name_id = name_id
        record.namespace_uri_id = namespace_uri_id
        record
      end
    end

    # :nodoc:
    #
    # Resolves *prefix_id* on element *index* through the namespace
    # declarations in scope. Returns the URI id, `NameTable::EMPTY_ID` for no
    # namespace (or an unbound empty prefix), or -1 when a prefix is unbound.
    def resolve_prefix(index : Int32, prefix_id : Int32) : Int32
      return @xml_namespace_id if prefix_id == @xml_prefix_id
      current = index
      while current >= 0
        if kind(current).element_node?
          attribute = data(current).first_attribute
          while attribute >= 0
            record = data(attribute)
            if record.kind.namespace_decl? && declared_prefix_id(record.name_id) == prefix_id
              return @names.intern(value_bytes(attribute))
            end
            attribute = record.next_sibling
          end
        end
        current = data(current).parent
      end
      prefix_id == NameTable::EMPTY_ID ? NameTable::EMPTY_ID : -1
    end

    # :nodoc:
    #
    # Returns the prefix id a namespace declaration attribute binds
    # (EMPTY_ID for `xmlns`).
    def declared_prefix_id(name_id : Int32) : Int32
      name_id == @xmlns_id ? NameTable::EMPTY_ID : @names.local_id(name_id)
    end

    # :nodoc:
    def xmlns_namespace_id : Int32
      @xmlns_namespace_id
    end

    # --- Document order -----------------------------------------------------

    private def mark_order_dirty : Nil
      @order_dirty = true
      @order_keys = nil
    end

    # :nodoc:
    #
    # True while arena index order equals document order (no mutation has
    # added or moved nodes since parsing).
    def index_order? : Bool
      !@order_dirty
    end

    # :nodoc:
    #
    # Returns a key that sorts nodes in document order. Detached nodes sort
    # after attached ones by index.
    def order_key(index : Int32) : Int32
      return index unless @order_dirty
      keys = @order_keys || compute_order_keys
      key = keys[index]
      key >= 0 ? key : @size + index
    end

    private def compute_order_keys : Array(Int32)
      keys = Array(Int32).new(@size, -1)
      counter = 0
      current = 0
      while current >= 0
        keys[current] = counter
        counter += 1
        attribute = data(current).first_attribute
        while attribute >= 0
          keys[attribute] = counter
          counter += 1
          attribute = data(attribute).next_sibling
        end
        current = following_in_order(current, 0)
      end
      @order_keys = keys
      keys
    end

    # :nodoc:
    #
    # Returns the next node after *index* in a depth-first walk confined to
    # the subtree of *root*, or -1.
    def following_in_order(index : Int32, root : Int32) : Int32
      first = data(index).first_child
      return first if first >= 0
      current = index
      while current != root && current >= 0
        following = data(current).next_sibling
        return following if following >= 0
        current = data(current).parent
      end
      -1
    end

    # :nodoc:
    #
    # Returns one past the last arena index in the subtree of *index*. Only
    # valid while `index_order?`.
    def subtree_end(index : Int32) : Int32
      current = index
      while current >= 0
        following = data(current).next_sibling
        return following if following >= 0 && !kind(following).attribute_node? && !kind(following).namespace_decl?
        current = data(current).parent
      end
      @size
    end
  end
end
