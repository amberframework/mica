module Mica::XML
  # A parsed XML document.
  #
  # Nodes live in an arena owned by the document: fixed-size records in
  # pages plus a chunked heap for names' values and text. `Mica::XML::Node` is a
  # small struct (document + index) pointing into it, so a large document
  # costs a few allocations instead of one object per node, and the garbage
  # collector never scans node records (they hold no pointers).
  #
  # A document answers the `Mica::XML::Node` API for its document node:
  #
  # ```
  # document = Mica::XML.parse(%(<feed><title>News</title></feed>))
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

    @pages = [] of Page
    @size = 0
    @chunks = [] of Bytes
    @chunk_used = CHUNK_SIZE
    @large_values = [] of Bytes
    @order_keys : Array(Int32)? = nil
    @merging_text_node = -1
    @text_merge_buffer = IO::Memory.new
    @order_dirty = false
    # Attribute lookups for elements the edit API has touched, built on
    # first use (see `AttributeIndex`).
    @attribute_indexes = {} of Int32 => AttributeIndex
    @xmlns_namespace_id : Int32
    @xml_namespace_id : Int32
    @xml_prefix_id : Int32
    @xmlns_id : Int32

    # True when the document was parsed with Namespaces in XML enforced
    # (`ParserOptions#namespace_aware`). Edits follow the same rules.
    getter? namespace_aware : Bool = true

    # The default budget for edits: the same rate as parsing, without a
    # deadline (edits are calls the application makes one at a time).
    DEFAULT_EDIT_BUDGET = Core::WorkBudget.new(operations_per_unit: 64, base_operations: 1_000_000)

    # The work budget edits run under (see `edit_meter`).
    getter edit_budget : Core::WorkBudget = DEFAULT_EDIT_BUDGET

    # Sets the edit budget. The next edit starts a fresh meter on it.
    def edit_budget=(budget : Core::WorkBudget) : Core::WorkBudget
      @edit_meter = nil
      @edit_budget = budget
    end

    @edit_meter : Core::WorkMeter? = nil

    # Bytes of all node values stored so far (the edit allowance counts
    # them, since an edit may read or copy any of them).
    @stored_value_bytes = 0_i64

    # :nodoc:
    #
    # The bytes of every value stored so far (text, attribute values and
    # other node values), for the work allowance of XPath and edits.
    def stored_value_bytes : Int64
      @stored_value_bytes
    end

    # Returns the meter that edits through `Node` (setting, renaming and
    # removing attributes, names and content) are charged to. Its units are
    # the document's nodes, name bytes and value bytes when it starts, plus
    # one per edit
    # call and the bytes each call is given (names, values, text), so the
    # work of any sequence of edits stays linear in the document and the
    # edits' input; a sequence that would do more stops with a
    # `Mica::WorkBudgetExceededError`. Created on the first edit.
    def edit_meter : Core::WorkMeter
      @edit_meter ||= new_edit_meter(@edit_budget)
    end

    # Replaces the edit meter with a fresh one for *budget*, for documents
    # that are edited in rounds over a long life.
    def renew_edit_meter(budget : Core::WorkBudget = @edit_budget) : Core::WorkMeter
      @edit_meter = new_edit_meter(budget)
    end

    private def new_edit_meter(budget : Core::WorkBudget) : Core::WorkMeter
      meter = Core::WorkMeter.new(budget)
      meter.add_units(@size + @names.name_bytes + @stored_value_bytes)
      meter
    end

    # :nodoc:
    #
    # Charges *count* operations of an edit; raises
    # `Mica::WorkBudgetExceededError` when the edit budget has run out.
    def charge_edit(count : Int) : Nil
      meter = edit_meter
      return unless meter.charge(count)
      meter.enforce("while editing the document") { Core::Position.new(0_i64) }
    end

    # :nodoc:
    #
    # Runs one edit call given *bytes* of input (names, values, text): adds
    # its units, charges validating, hashing and copying the input before
    # anything else (also when the edit then fails), takes a private copy
    # of a name table shared with a reader (`Reader#expand`), and points
    # the table's rehash hook at the edit meter for the duration.
    def editing(bytes : Int64, &)
      meter = edit_meter
      meter.add_units(bytes + 1)
      # Validating, hashing and comparing the input (names are checked as
      # Names, then as QNames, split and interned): charged first.
      charge_edit(4_i64 * bytes + 1)
      # The budget and the deadline are checked before anything changes,
      # also for an edit too small to reach a clock checkpoint. A finished
      # edit is never reported as failed (see `settle_name_work`).
      meter.enforce("while editing the document") { Core::Position.new(0_i64) }
      unshare_names if @shared_names
      previous_hook = @names.before_rebuild
      @names.before_rebuild = edit_rebuild_hook
      unpaid_before = @names.unpaid_operations
      lookups_before = @names.lookup_operations
      begin
        yield
      ensure
        @names.before_rebuild = previous_hook
        settle_name_work(unpaid_before, lookups_before)
      end
    end

    # Gives the document its own copy of a name table shared with a reader,
    # so edits never add names, lookups or later rehash work to the
    # reader's table and meter. The copy is linear in the table and charged
    # here; the edit allowance already counts the table's name bytes.
    private def unshare_names : Nil
      charge_edit(@names.copy_work)
      @names = @names.copy
      @shared_names = false
    end

    # Charges the name-table work an edit did (lookups and interning) to
    # the edit meter, marking the interning work paid so a reader sharing
    # the table never charges it to its parse.
    #
    # It runs after the edit, so it records the work without raising: an
    # edit that completed is never reported as failed, and the next edit's
    # charge at entry trips if the budget ran out.
    private def settle_name_work(unpaid_before : Int64, lookups_before : Int64) : Nil
      work = @names.unpaid_operations - unpaid_before
      @names.mark_paid(work) if work > 0
      work += @names.lookup_operations - lookups_before
      edit_meter.charge(work) if work > 0
    end

    private def edit_rebuild_hook : Proc(Int64, Nil)
      @edit_rebuild_hook ||= ->(work : Int64) { charge_edit(work) }
    end

    @edit_rebuild_hook : Proc(Int64, Nil)? = nil

    # True while the document uses a name table it shares with the reader
    # that built it (`Reader#expand`); the first edit takes a private copy.
    @shared_names = false

    # :nodoc:
    #
    # With *shared_names*, *names* belongs to a reader that keeps parsing.
    def initialize(@names : NameTable = NameTable.new, *, @shared_names : Bool = false)
      @xmlns_namespace_id = @names.intern(Reader::XMLNS_NAMESPACE)
      @xml_namespace_id = @names.intern(Reader::XML_NAMESPACE)
      @xml_prefix_id = @names.intern("xml")
      @xmlns_id = @names.intern("xmlns")
      add_node(Node::Type::DOCUMENT_NODE, -1, 0, 0, Bytes.empty)
    end

    # Parses *source* into a document. See `Mica::XML.parse`.
    def self.parse(source : String | Bytes | IO, options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil) : Document
      reader = Reader.new(source, options, meter)
      document = new(reader.names)
      document.build_from(reader)
      # The finished document owns the names now; rehashes that later
      # edits cause are charged to the edit meter (see `editing`).
      reader.names.before_rebuild = nil
      document
    end

    # Returns the operations the parse that built this document charged
    # (reading and building together).
    getter parse_operations : Int64 = 0_i64

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
      start = reader.operations
      parent = 0
      while reader.read
        parent = add_event(reader, parent)
      end
      finish_text_merge(reader)
      copy_prolog(reader)
      @parse_operations = reader.operations - start
    end

    # :nodoc:
    #
    # Builds the subtree of the element the reader is on, then leaves the
    # reader on that element's end.
    def build_subtree_from(reader : Reader) : Nil
      start_operations = reader.operations
      @namespace_aware = reader.options.namespace_aware?
      copy_prolog(reader)
      depth = reader.event_depth
      name_id = reader.event_name_id
      namespace_uri_id = reader.event_namespace_uri_id
      # The reader already returned this element: charge its copy here, as
      # add_event does for the rest.
      reader.charge(1 + attribute_bytes(reader))
      element = add_element(reader, 0)
      @expansion = Expansion.new(element, reader.event_binding_mark, last_attribute(reader, element)) if @namespace_aware
      declare_inherited_namespaces(reader)
      unless reader.empty_element?
        parent = element
        while reader.read
          break if reader.event_type.end_element? && reader.event_depth == depth
          parent = add_event(reader, parent)
        end
        finish_text_merge(reader)
      end
      reader.finish_expand(name_id, namespace_uri_id, depth)
      reader.settle_name_operations
      @expansion = nil
      @parse_operations = reader.operations - start_operations
    end

    # An expansion in progress (`build_subtree_from`): the subtree's root
    # element, the reader's binding mark at it, the root's last attribute
    # and the prefixes already declared on the root for the subtree.
    private class Expansion
      getter root : Int32
      getter binding_mark : Int32
      property tail : Int32
      getter declared = Set(Int32).new

      def initialize(@root : Int32, @binding_mark : Int32, @tail : Int32)
      end
    end

    @expansion : Expansion? = nil

    private def last_attribute(reader : Reader, element : Int32) : Int32
      # One step per copied attribute: charged first.
      reader.charge(reader.event_attributes.size)
      last = -1
      current = data(element).first_attribute
      while current >= 0
        last = current
        current = data(current).next_sibling
      end
      last
    end

    # Declares on the subtree's root each namespace binding that the current
    # start tag uses but that an ancestor outside the subtree declared, so
    # the expanded document stands alone (its markup and XPath prefixes
    # resolve). Each prefix is declared once; the check is constant work per
    # name, charged with the tag, and each declaration is charged.
    private def declare_inherited_namespaces(reader : Reader) : Nil
      expansion = @expansion || return
      # The walk below visits every attribute: charged first.
      reader.charge(reader.event_attributes.size)
      declare_inherited(reader, expansion, reader.event_name_id, reader.event_namespace_uri_id)
      reader.event_attributes.each do |slot|
        uri_id = slot.namespace_uri_id
        next if uri_id == NameTable::EMPTY_ID || uri_id == @xmlns_namespace_id
        declare_inherited(reader, expansion, slot.name_id, uri_id)
      end
    end

    private def declare_inherited(reader : Reader, expansion : Expansion, name_id : Int32, uri_id : Int32) : Nil
      return if uri_id == NameTable::EMPTY_ID || uri_id == @xml_namespace_id
      prefix_id = @names.prefix_id(name_id)
      return if expansion.declared.includes?(prefix_id)
      return if reader.inherited_binding_uri(prefix_id, expansion.binding_mark) != uri_id
      expansion.declared << prefix_id
      uri = @names[uri_id].to_slice
      # Building, hashing and comparing the declaration's name, and storing
      # the URI: charged first (the table's count is settled at the end).
      reader.charge(2_i64 + uri.size + 3_i64 * (@names[prefix_id].bytesize + 6))
      declaration_id = prefix_id == NameTable::EMPTY_ID ? @xmlns_id : @names.intern("xmlns:#{@names[prefix_id]}")
      expansion.tail = add_attribute_node(Node::Type::NAMESPACE_DECL, expansion.root, declaration_id, @xmlns_namespace_id, uri, expansion.tail)
      mark_order_dirty
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

    # Adds the node for the reader's current event under *parent* and
    # returns the parent for the next event. Each event is charged before
    # anything is copied: one record per node plus the bytes copied. An end
    # tag only moves to the parent; the reader's per-token charge covers it.
    private def add_event(reader : Reader, parent : Int32) : Int32
      type = reader.event_type
      finish_text_merge_before(reader, type)
      case type
      when .element?
        reader.charge(1 + attribute_bytes(reader))
        element = add_element(reader, parent)
        declare_inherited_namespaces(reader)
        return element unless reader.empty_element?
      when .end_element?
        return data(parent).parent
      when .document_type?
        reader.charge(1)
        append_new(Node::Type::DTD_NODE, parent, reader.event_name_id, 0, Bytes.empty)
      when .entity_reference?
        reader.charge(1)
        append_new(Node::Type::ENTITY_REF_NODE, parent, reader.event_name_id, 0, Bytes.empty)
      else
        value = reader.value_bytes
        reader.charge(1 + value.size)
        case type
        when .text?, .significant_whitespace?
          add_text(reader, parent, value)
        when .cdata?
          append_new(Node::Type::CDATA_SECTION_NODE, parent, 0, 0, value)
        when .comment?
          append_new(Node::Type::COMMENT_NODE, parent, 0, 0, value)
        when .processing_instruction?
          append_new(Node::Type::PI_NODE, parent, reader.event_name_id, 0, value)
        end
      end
      parent
    end

    @[AlwaysInline]
    private def add_element(reader : Reader, parent : Int32) : Int32
      element = append_new(Node::Type::ELEMENT_NODE, parent, reader.event_name_id, reader.event_namespace_uri_id, Bytes.empty)
      previous = -1
      reader.event_attributes.each do |slot|
        kind = slot.namespace_uri_id == @xmlns_namespace_id ? Node::Type::NAMESPACE_DECL : Node::Type::ATTRIBUTE_NODE
        value = reader.attribute_value_bytes(slot)
        previous = add_attribute_node(kind, element, slot.name_id, slot.namespace_uri_id, value, previous)
      end
      element
    end

    # Returns the work of copying the current start tag's attributes: one
    # record and the value bytes for each.
    private def attribute_bytes(reader : Reader) : Int64
      # The tally itself passes over every attribute: charged first.
      reader.charge(reader.event_attributes.size)
      total = 0_i64
      reader.event_attributes.each do |slot|
        total += 1 + slot.value_size
      end
      total
    end

    # Adds text under *parent*. Adjacent text events (around entity
    # boundaries) merge into one node; the merged text is collected in a
    # buffer and stored once, so merging stays linear. Each copy is charged
    # before it happens (the new bytes are charged with their event).
    @[AlwaysInline]
    private def add_text(reader : Reader, parent : Int32, bytes : Bytes) : Nil
      last = data(parent).last_child
      if last >= 0 && data(last).kind.text_node?
        if @merging_text_node != last
          reader.charge(value_bytes(last).size)
          @text_merge_buffer.clear
          @text_merge_buffer.write(value_bytes(last))
          @merging_text_node = last
        end
        @text_merge_buffer.write(bytes)
        return
      end
      append_new(Node::Type::TEXT_NODE, parent, 0, 0, bytes)
    end

    private def finish_text_merge_before(reader : Reader, type : Reader::Type) : Nil
      return if @merging_text_node < 0
      finish_text_merge(reader) unless type.text? || type.significant_whitespace?
    end

    private def finish_text_merge(reader : Reader) : Nil
      node = @merging_text_node
      return if node < 0
      reader.charge(@text_merge_buffer.bytesize)
      store_value(node, @text_merge_buffer.to_slice)
      @merging_text_node = -1
      @text_merge_buffer.clear
    end

    # :nodoc:
    #
    # Returns the record of node *index*. Raises `IndexError` for an index
    # that was never allocated.
    @[AlwaysInline]
    def data(index : Int32) : NodeData
      check_index(index)
      @pages[index >> PAGE_BITS][index & PAGE_MASK]
    end

    # One page of PAGE_SIZE node records. The records live inline in a
    # StaticArray, so an offset masked with PAGE_MASK is provably in bounds
    # and the compiler drops the check; no raw pointers are involved.
    # Records are written by `add_node` before anything reads them (reads
    # are limited to indexes below `@size`).
    private class Page
      @records = uninitialized StaticArray(NodeData, PAGE_SIZE)

      @[AlwaysInline]
      def [](offset : Int32) : NodeData
        @records[offset]
      end

      @[AlwaysInline]
      def []=(offset : Int32, record : NodeData) : NodeData
        @records[offset] = record
      end
    end

    @[AlwaysInline]
    private def check_index(index : Int32) : Nil
      raise IndexError.new("Node index #{index} out of range") unless index >= 0 && index < @size
    end

    # Replaces the record of node *index*.
    @[AlwaysInline]
    private def write_data(index : Int32, record : NodeData) : Nil
      check_index(index)
      @pages[index >> PAGE_BITS][index & PAGE_MASK] = record
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
        @large_values[-ref - 1]
      else
        @chunks[ref >> CHUNK_BITS][ref & CHUNK_MASK, size]
      end
    end

    # :nodoc:
    def value_string(index : Int32) : String
      String.new(value_bytes(index))
    end

    # Creates node *index* with its links and value in one record write.
    @[AlwaysInline]
    private def add_node(kind : Node::Type, parent : Int32, name_id : Int32, namespace_uri_id : Int32, value : Bytes, previous_sibling : Int32 = -1) : Int32
      index = @size
      if index & PAGE_MASK == 0
        if index == Int32::MAX & ~PAGE_MASK
          raise Error.new("Document exceeds the maximum node count")
        end
        @pages << Page.new
      end
      @size += 1
      record = NodeData.new(kind)
      record.parent = parent
      record.previous_sibling = previous_sibling
      record.name_id = name_id
      record.namespace_uri_id = namespace_uri_id
      unless value.empty?
        record.value_ref = copy_value(value)
        record.value_size = value.size
      end
      # index is @size - 1, so only the page lookup needs its check.
      @pages[index >> PAGE_BITS][index & PAGE_MASK] = record
      index
    end

    # Adds a node as the last child of *parent*.
    @[AlwaysInline]
    private def append_new(kind : Node::Type, parent : Int32, name_id : Int32, namespace_uri_id : Int32, value : Bytes) : Int32
      parent_record = data(parent)
      last = parent_record.last_child
      child = add_node(kind, parent, name_id, namespace_uri_id, value, last)
      if last < 0
        parent_record.first_child = child
      else
        update(last) { |record| record.next_sibling = child; record }
      end
      parent_record.last_child = child
      write_data(parent, parent_record)
      child
    end

    # :nodoc:
    #
    # Copies *value* into the heap and points node *index* at it.
    def store_value(index : Int32, value : Bytes) : Nil
      ref = value.empty? ? 0 : copy_value(value)
      record = data(index)
      record.value_ref = ref
      record.value_size = value.size
      write_data(index, record)
    end

    # Copies non-empty *value* into the value heap and returns its
    # reference: a chunk offset, or a negative large-value index.
    private def copy_value(value : Bytes) : Int32
      @stored_value_bytes += value.size
      size = value.size
      if size > LARGE_VALUE
        @large_values << value.dup
        return -@large_values.size
      end
      if @chunk_used + size > CHUNK_SIZE
        raise Error.new("Document text exceeds 2 GiB") if @chunks.size >= MAX_CHUNKS
        @chunks << Bytes.new(CHUNK_SIZE)
        @chunk_used = 0
      end
      Core::ByteScan.copy_into(@chunks.last, @chunk_used, value)
      ref = ((@chunks.size - 1) << CHUNK_BITS) + @chunk_used
      @chunk_used += size
      ref
    end

    # Adds an attribute node after *previous* (or first, when *previous* is
    # -1) in *element*'s attribute list.
    private def add_attribute_node(kind : Node::Type, element : Int32, name_id : Int32, namespace_uri_id : Int32, value : Bytes, previous : Int32) : Int32
      attribute = add_node(kind, element, name_id, namespace_uri_id, value, previous)
      if previous < 0
        update(element) { |record| record.first_attribute = attribute; record }
      else
        update(previous) { |record| record.next_sibling = attribute; record }
      end
      attribute
    end

    # Applies a change to the record of node *index*.
    @[AlwaysInline]
    private def update(index : Int32, & : NodeData -> NodeData) : Nil
      write_data(index, yield data(index))
    end

    # --- Mutation (used by Mica::XML::Node) -------------------------------------

    # :nodoc:
    def set_value(index : Int32, value : String) : Nil
      charge_edit(1 + value.bytesize)
      store_value(index, value.to_slice)
    end

    # :nodoc:
    #
    # Detaches node *index* from its parent (or element, for attributes).
    def unlink(index : Int32) : Nil
      charge_edit(1)
      record = data(index)
      parent = record.parent
      return if parent < 0
      previous = record.previous_sibling
      following = record.next_sibling
      attribute = record.kind.attribute_node? || record.kind.namespace_decl?
      if attribute_index = attribute_owner_index(record)
        unindex_attribute(attribute_index, index)
        attribute_index.tail = previous if attribute_index.tail == index
      end
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
      charge_edit(1 + text.bytesize)
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
    # The attribute list of one edited element, indexed so that each edit
    # costs O(1) expected instead of a walk over the list: the attribute (or
    # namespace declaration) for each qualified name id, the attribute for
    # each expanded name, the declaration for each prefix, the attributes
    # for each local name in list order, and the list tail. Built once per
    # element with one walk, then kept current by `append_attribute`,
    # `unlink` and `rename`, so *n* edits on an element cost O(n + k) for
    # *k* parsed attributes.
    class AttributeIndex
      getter by_name = {} of Int32 => Int32
      getter by_expanded_name = {} of {Int32, Int32} => Int32
      getter by_declared_prefix = {} of Int32 => Int32
      # Attribute nodes by local name id, in list order (by `order`). Entries
      # of removed or renamed attributes stay until they reach the front,
      # where a lookup steps past them, so each entry is passed once.
      getter by_local_name = {} of Int32 => LocalCandidates
      # The position of each indexed attribute in the list (increasing).
      getter order = {} of Int32 => Int32
      property next_order = 0
      property tail : Int32 = -1
    end

    # :nodoc:
    #
    # The attributes sharing one local name, in list order, from `head` on
    # (entries before `head` were stepped past).
    class LocalCandidates
      getter list = [] of Int32
      property head = 0
    end

    # :nodoc:
    #
    # Returns the attribute or namespace declaration of *element* named
    # *name_id*, or nil.
    def attribute_named(element : Int32, name_id : Int32) : Int32?
      attribute_index(element).by_name[name_id]?
    end

    # :nodoc:
    #
    # Returns the attribute of *element* with the expanded name
    # {*uri_id*, *local_id*}, or nil.
    def attribute_with_expanded_name(element : Int32, uri_id : Int32, local_id : Int32) : Int32?
      attribute_index(element).by_expanded_name[{uri_id, local_id}]?
    end

    # :nodoc:
    #
    # Returns the first attribute of *element* (in list order) whose local
    # name is *local_id*, or nil. Each stale candidate is stepped past once;
    # an edit (*for_edit*) charges the steps to the edit meter, while a
    # plain read stays unmetered.
    def attribute_with_local_name(element : Int32, local_id : Int32, for_edit : Bool) : Int32?
      candidates = attribute_index(element).by_local_name[local_id]? || return
      list = candidates.list
      while candidates.head < list.size
        charge_edit(1) if for_edit
        first = list[candidates.head]
        record = data(first)
        return first if record.parent == element && record.kind.attribute_node? && split_local_id(record.name_id) == local_id
        candidates.head += 1
      end
      nil
    end

    # :nodoc:
    #
    # True when *element* has an attribute index (it was edited).
    def attribute_index?(element : Int32) : Bool
      @attribute_indexes.has_key?(element)
    end

    # :nodoc:
    #
    # Returns the local part of name *name_id* as bytes, without interning
    # (the whole name without namespace processing).
    def local_name_bytes(name_id : Int32) : Bytes
      @namespace_aware ? @names.local_bytes(name_id) : @names[name_id].to_slice
    end

    # :nodoc:
    #
    # Builds *element*'s attribute index (an edit is about to search it).
    def index_attributes(element : Int32) : Nil
      attribute_index(element)
    end

    # Retrieving a built index is one map lookup, covered by each caller's
    # per-call charge (plain reads stay unmetered); building one charges
    # its insertion and every attribute it indexes.
    private def attribute_index(element : Int32) : AttributeIndex
      @attribute_indexes[element] ||= begin
        charge_edit(1)
        index = AttributeIndex.new
        current = data(element).first_attribute
        while current >= 0
          charge_edit(1)
          index.order[current] = index.next_order
          index.next_order += 1
          index_attribute(index, current)
          index.tail = current
          current = data(current).next_sibling
        end
        index
      end
    end

    # Adds *attribute* to *index*. With *prepaid*, the caller charged
    # `index_work` before changing the tree, so nothing here can raise and
    # leave the tree and its index out of step.
    private def index_attribute(index : AttributeIndex, attribute : Int32, prepaid : Bool = false) : Nil
      charge_edit(INDEX_MAP_OPERATIONS) unless prepaid
      record = data(attribute)
      index.by_name[record.name_id] ||= attribute
      if record.kind.namespace_decl?
        index.by_declared_prefix[declared_prefix_id(record.name_id)] ||= attribute
        return
      end
      local_id = split_local_id(record.name_id)
      if record.namespace_uri_id != NameTable::EMPTY_ID
        index.by_expanded_name[{record.namespace_uri_id, local_id}] ||= attribute
      end
      insert_in_order(index, index.by_local_name.put_if_absent(local_id) { LocalCandidates.new }, attribute, prepaid)
    end

    # The record plus a read and a write in each of the by-name, by-prefix
    # or by-expanded-name and candidate maps.
    private INDEX_MAP_OPERATIONS = 7_i64

    # The work `index_attribute` will charge for *attribute* (-1 for one
    # not yet added) named *name_id* of *kind* at list position *position*,
    # computed without changing anything (the steps `insert_in_order`
    # takes).
    private def index_work(index : AttributeIndex, attribute : Int32, name_id : Int32, kind : Node::Type, position : Int32) : Int64
      work = INDEX_MAP_OPERATIONS
      return work if kind.namespace_decl?
      # The candidate lookup and the order read below: charged first.
      charge_edit(2)
      candidates = index.by_local_name[split_local_id(name_id)]? || return work
      list = candidates.list
      head = candidates.head
      live = list.size
      if head > 0 && head * 2 >= list.size
        work += list.size
        live = list.size - head
      end
      last = list.last?
      return work if last.nil? || index.order[last] < position
      # The search below is charged before it runs; insert_in_order's own
      # count of it is part of the returned work.
      search = 65 - live.leading_zeros_count
      charge_edit(search)
      work += Math.log2(live + 1).ceil.to_i + 1
      at = (head...list.size).bsearch { |slot| index.order[list[slot]] >= position } || list.size
      return work if list[at]? == attribute
      work + list.size - at
    end

    # Inserts *attribute* into *candidates* by list position. Appends land
    # at the end in O(1); a rename finds its place by binary search and
    # moves the later candidates, all charged. Stepped-past entries are
    # dropped first when they are at least half the list, so the list
    # stays proportional to its live entries.
    private def insert_in_order(index : AttributeIndex, candidates : LocalCandidates, attribute : Int32, prepaid : Bool) : Nil
      list = candidates.list
      if candidates.head > 0 && candidates.head * 2 >= list.size
        charge_edit(list.size) unless prepaid
        list.delete_at(0, candidates.head)
        candidates.head = 0
      end
      position = index.order[attribute]
      last = list.last?
      if last.nil? || index.order[last] < position
        list << attribute
        return
      end
      charge_edit(Math.log2(list.size + 1).ceil.to_i + 1) unless prepaid
      at = (candidates.head...list.size).bsearch { |slot| index.order[list[slot]] >= position } || list.size
      return if list[at]? == attribute
      charge_edit(list.size - at) unless prepaid
      list.insert(at, attribute)
    end

    private def unindex_attribute(index : AttributeIndex, attribute : Int32) : Nil
      # Up to three map lookups and three deletions.
      charge_edit(6)
      record = data(attribute)
      index.by_name.delete(record.name_id) if index.by_name[record.name_id]? == attribute
      key = {record.namespace_uri_id, split_local_id(record.name_id)}
      index.by_expanded_name.delete(key) if index.by_expanded_name[key]? == attribute
      if record.kind.namespace_decl?
        prefix_id = declared_prefix_id(record.name_id)
        index.by_declared_prefix.delete(prefix_id) if index.by_declared_prefix[prefix_id]? == attribute
      end
    end

    # :nodoc:
    #
    # Adds an attribute (or namespace declaration) at the end of the
    # element's attribute list.
    def append_attribute(element : Int32, name_id : Int32, namespace_uri_id : Int32, value : String, kind : Node::Type) : Int32
      charge_edit(1 + value.bytesize)
      index = attribute_index(element)
      # Every charge comes before the tree changes, so a budget trip leaves
      # the tree and its index unchanged.
      # The index work and the prefix-use count update (a read and a
      # write).
      charge_edit(index_work(index, -1, name_id, kind, index.next_order) + 2)
      attribute = add_attribute_node(kind, element, name_id, namespace_uri_id, value.to_slice, index.tail)
      index.order[attribute] = index.next_order
      index.next_order += 1
      index_attribute(index, attribute, prepaid: true)
      index.tail = attribute
      count_name_use(name_id, 1) if kind.attribute_node?
      mark_order_dirty
      attribute
    end

    # :nodoc:
    def rename(index : Int32, name_id : Int32, namespace_uri_id : Int32) : Nil
      charge_edit(1)
      record = data(index)
      named = record.kind.element_node? || record.kind.attribute_node?
      attribute_index = attribute_owner_index(record)
      # Every charge comes before the tree changes, so a budget trip leaves
      # the tree and its index unchanged.
      charge_edit(index_work(attribute_index, index, name_id, record.kind, attribute_index.order[index])) if attribute_index
      # The two prefix-use count updates (a read and a write each).
      charge_edit(4)
      unindex_attribute(attribute_index, index) if attribute_index
      count_name_use(record.name_id, -1) if named
      write_rename(index, name_id, namespace_uri_id)
      count_name_use(name_id, 1) if named
      index_attribute(attribute_index, index, prepaid: true) if attribute_index
    end

    # The index of the element owning attribute *record*, when one was built.
    private def attribute_owner_index(record : NodeData) : AttributeIndex?
      return unless record.kind.attribute_node? || record.kind.namespace_decl?
      return if record.parent < 0
      @attribute_indexes[record.parent]?
    end

    private def write_rename(index : Int32, name_id : Int32, namespace_uri_id : Int32) : Nil
      update(index) do |record|
        record.name_id = name_id
        record.namespace_uri_id = namespace_uri_id
        record
      end
    end

    # Number of element and attribute nodes (attached or detached) named
    # with each prefix id, counted once on first use and then kept current
    # by renames and new attributes. A prefix with no count is used by no
    # node, so a new declaration of it cannot change how any name resolves.
    @prefix_use_counts : Hash(Int32, Int32)? = nil

    # :nodoc:
    #
    # True when some element or attribute node of the document (attached or
    # detached) has a name with *prefix_id*.
    def prefix_used?(prefix_id : Int32) : Bool
      counts = @prefix_use_counts ||= count_prefix_uses
      counts.fetch(prefix_id, 0) > 0
    end

    private def count_prefix_uses : Hash(Int32, Int32)
      # A visit, a read and a write per node: charged first.
      charge_edit(3_i64 * @size)
      counts = {} of Int32 => Int32
      @size.times do |node|
        record = data(node)
        next unless record.kind.element_node? || record.kind.attribute_node?
        prefix_id = @names.prefix_id(record.name_id)
        counts[prefix_id] = counts.fetch(prefix_id, 0) + 1
      end
      counts
    end

    # Its read and write are charged by the caller before the tree changes.
    private def count_name_use(name_id : Int32, delta : Int32) : Nil
      counts = @prefix_use_counts || return
      prefix_id = @names.prefix_id(name_id)
      counts[prefix_id] = counts.fetch(prefix_id, 0) + delta
    end

    # :nodoc:
    #
    # Resolves *prefix_id* on element *index* through the namespace
    # declarations in scope. Returns the URI id, `NameTable::EMPTY_ID` for no
    # namespace (or an unbound empty prefix), or -1 when a prefix is unbound.
    # Used by edits: each element on the way is indexed (once), so a
    # resolution costs O(depth) after the first, not the size of the
    # attribute lists; the walk is charged to the edit meter.
    def resolve_prefix(index : Int32, prefix_id : Int32) : Int32
      return @xml_namespace_id if prefix_id == @xml_prefix_id
      current = index
      while current >= 0
        # The step and the declaration-map lookup (attribute_index charges
        # its own lookup).
        charge_edit(2)
        if kind(current).element_node?
          if declaration = attribute_index(current).by_declared_prefix[prefix_id]?
            uri = value_bytes(declaration)
            # Interning hashes and compares the URI: both passes first.
            charge_edit(2_i64 * uri.size)
            # An XML 1.1 `xmlns:p=""` undeclares p.
            return -1 if uri.empty? && prefix_id != NameTable::EMPTY_ID
            return @names.intern(uri)
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
      name_id == @xmlns_id ? NameTable::EMPTY_ID : split_local_id(name_id)
    end

    # :nodoc:
    #
    # Returns `NameTable#local_id` of *name_id*. Splitting a name interns
    # its parts; in a table shared with a reader (`Reader#expand`) that
    # work is the document's, so `own_name_work` keeps it off the reader.
    #
    # Without namespace processing a name is one unit: its local part is
    # the whole name and it has no prefix.
    def split_local_id(name_id : Int32) : Int32
      return name_id unless @namespace_aware
      return @names.local_id(name_id) if !@shared_names || @names.split?(name_id)
      own_name_work { @names.local_id(name_id) }
    end

    # :nodoc:
    #
    # Returns `NameTable#prefix_id` of *name_id*, like `split_local_id`.
    def split_prefix_id(name_id : Int32) : Int32
      return NameTable::EMPTY_ID unless @namespace_aware
      return @names.prefix_id(name_id) if !@shared_names || @names.split?(name_id)
      own_name_work { @names.prefix_id(name_id) }
    end

    # Runs the block's name-table work as the document's own: with the
    # reader's rehash hook detached and the work marked paid, so the
    # reader never charges it to its parse. Reads are not metered; the
    # work is linear in the name split plus amortized growth.
    private def own_name_work(& : -> Int32) : Int32
      hook = @names.before_rebuild
      @names.before_rebuild = nil
      unpaid_before = @names.unpaid_operations
      begin
        yield
      ensure
        @names.before_rebuild = hook
        work = @names.unpaid_operations - unpaid_before
        @names.mark_paid(work) if work > 0
      end
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
    # True when `order_key` can answer without walking the whole document.
    def order_keys_ready? : Bool
      !@order_dirty || !@order_keys.nil?
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
      following_in_order(index, root) { }
    end

    # :nodoc:
    #
    # Same, calling the block once per parent link climbed, so a metered
    # caller can charge the climb.
    def following_in_order(index : Int32, root : Int32, & : ->) : Int32
      first = data(index).first_child
      return first if first >= 0
      current = index
      while current != root && current >= 0
        yield
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
      subtree_end(index) { }
    end

    # :nodoc:
    #
    # Same, calling the block once per parent link climbed, so a metered
    # caller can charge the climb.
    def subtree_end(index : Int32, & : ->) : Int32
      current = index
      while current >= 0
        yield
        following = data(current).next_sibling
        return following if following >= 0 && !kind(following).attribute_node? && !kind(following).namespace_decl?
        current = data(current).parent
      end
      @size
    end
  end
end
