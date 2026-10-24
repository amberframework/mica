require "./reader/type"

module Mica::XML
  # A pull parser that walks an XML document one node at a time.
  #
  # The API mirrors stdlib `XML::Reader`, so code written against it ports by
  # changing the constant. It parses XML 1.0 (5th edition) and XML 1.1 (2nd
  # edition, chosen by the document's declaration) with Namespaces in XML,
  # checks well-formedness as it goes, and raises `Mica::ParseError` (with
  # line, column and byte offset) at the first error instead of recovering.
  #
  # ```
  # reader = Mica::XML::Reader.new(%(<message lang="en">Hello XML!</message>))
  # reader.read
  # reader.name    # => "message"
  # reader["lang"] # => "en"
  # reader.read
  # reader.value # => "Hello XML!"
  # ```
  #
  # Built from an `IO`, the reader streams: it keeps one buffer that holds
  # the current token, so memory stays flat on large documents.
  #
  # Every read draws on a `Core::WorkMeter` (from
  # `ParserOptions#work_budget`, or one passed in), so the work done stays
  # linear in the bytes read; see `ParserOptions`.
  #
  # WARNING: This type is not concurrency-safe.
  class Reader
    include Core::ByteInput
    include Core::LineTracking

    # :nodoc:
    #
    # One attribute of the current start tag. A value lives either in the
    # input buffer (offset relative to the token mark) or in the scratch
    # buffer.
    record AttributeSlot,
      name_id : Int32,
      value_start : Int32,
      value_size : Int32,
      in_scratch : Bool,
      namespace_uri_id : Int32,
      specified : Bool

    # :nodoc:
    #
    # The saved state of an outer source while an entity's replacement text
    # is being read.
    record SourceFrame,
      buffer : Bytes,
      pos : Int32,
      limit : Int32,
      mark : Int32,
      pin : Int32,
      io : IO?,
      io_eof : Bool,
      base_offset : Int64,
      entity : DTD::Entity?

    private enum Phase
      Start
      Prolog
      Content
      Epilog
      Done
    end

    XML_NAMESPACE   = "http://www.w3.org/XML/1998/namespace"
    XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"

    # Operations charged per token on top of its bytes (event bookkeeping).
    private TOKEN_OPERATIONS = 4

    # Returns the options this reader enforces.
    getter options : ParserOptions

    # Returns the work meter this reader charges.
    getter meter : Core::WorkMeter

    # Returns the version from the XML declaration (`"1.0"` when absent).
    getter xml_version : String = "1.0"

    # Returns the encoding the document was decoded from (`"UTF-8"`,
    # `"UTF-16"`, `"ISO-8859-1"` or `"US-ASCII"`).
    getter encoding : String = "UTF-8"

    # Returns true when the XML declaration says `standalone="yes"`.
    getter? standalone : Bool = false

    # :nodoc:
    getter names : NameTable

    # :nodoc:
    getter dtd : DTD

    # Input state beyond `Core::ByteInput`.
    @frames = [] of SourceFrame
    @current_entity : DTD::Entity? = nil
    @in_document_source = true
    @ascii_only = false
    @encoding_problem : String? = nil
    @signature : Core::Encoding = Core::Encoding::UTF8
    # True once a version="1.1" declaration has been read: XML 1.1 line
    # ends, characters and namespace undeclaration apply.
    @xml11 = false

    # Event state.
    @phase = Phase::Start
    @node_type = Type::NONE
    @event_depth = 0
    @name_id = 0
    @namespace_uri_id = 0
    @value_start = 0
    @value_size = 0
    @value_in_scratch = false
    @empty_element = false
    @attrs = [] of AttributeSlot
    @attr_index = -1
    @attribute_lookup = {} of Int32 => Int32
    @scratch : Bytes = Bytes.new(4096)
    @scratch_size = 0

    # Tree state.
    @open_names = [] of Int32
    @open_namespace_uris = [] of Int32
    @open_binding_marks = [] of Int32
    @open_entity_levels = [] of Int32
    # Namespace bindings: parallel stacks, plus for each prefix id the index
    # of its innermost binding, so a prefix resolves in O(1).
    @binding_prefixes = [] of Int32
    @binding_uris = [] of Int32
    @binding_previous = [] of Int32
    @innermost_binding = [] of Int32
    @pending_binding_mark = -1
    @pending_entity : DTD::Entity? = nil
    @pending_skipped_entity_id = -1
    @root_seen = false
    @doctype_seen = false
    @parameter_entity_referenced = false

    # Entity expansion accounting.
    @expansion_count = 0
    @expansion_bytes = 0_i64
    @attribute_entity_stack = [] of DTD::Entity

    # Name-table probes already charged to the meter.
    @charged_probes = 0_i64

    # Interned names used by the scanner.
    @xmlns_id : Int32
    @xml_id : Int32
    @xml_namespace_id : Int32
    @xmlns_namespace_id : Int32
    @predefined_ids : StaticArray(Int32, 5)

    # Creates a reader over *string*. The string's bytes are read in place.
    def self.new(string : String, options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil) : self
      new(string.to_slice, options, meter)
    end

    # Creates a reader over *bytes* (UTF-8, or UTF-16 with a byte order
    # mark). The bytes are read in place and must not change while the
    # reader is in use. *meter* lets several operations share one budget;
    # without it the reader starts a meter from `options.work_budget`.
    def initialize(bytes : Bytes, @options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil)
      @meter = meter || Core::WorkMeter.new(@options.work_budget)
      @names = NameTable.new
      @dtd = DTD.new
      @xmlns_id = @names.intern("xmlns")
      @xml_id = @names.intern("xml")
      @xml_namespace_id = @names.intern(XML_NAMESPACE)
      @xmlns_namespace_id = @names.intern(XMLNS_NAMESPACE)
      @predefined_ids = StaticArray[@names.intern("lt"), @names.intern("gt"), @names.intern("amp"), @names.intern("apos"), @names.intern("quot")]
      setup_bytes(bytes)
    end

    # Creates a streaming reader over *io*.
    def initialize(io : IO, @options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil)
      @meter = meter || Core::WorkMeter.new(@options.work_budget)
      @names = NameTable.new
      @dtd = DTD.new
      @xmlns_id = @names.intern("xmlns")
      @xml_id = @names.intern("xml")
      @xml_namespace_id = @names.intern(XML_NAMESPACE)
      @xmlns_namespace_id = @names.intern(XMLNS_NAMESPACE)
      @predefined_ids = StaticArray[@names.intern("lt"), @names.intern("gt"), @names.intern("amp"), @names.intern("apos"), @names.intern("quot")]
      setup_io(io)
    end

    # Returns the operations charged to this reader's meter so far.
    def operations : Int64
      @meter.operations
    end

    # Moves to the next node. Returns false at the end of the document.
    #
    # Raises `Mica::ParseError` when the document is not well-formed and
    # `Mica::LimitExceededError` (including `Mica::WorkBudgetExceededError`
    # and `Mica::DeadlineExceededError`) when a limit trips.
    def read : Bool
      @attr_index = -1
      return false if @phase.done?
      if @phase.start?
        start_document
      end
      advance
    end

    # Returns the type of the node the reader is positioned on.
    def node_type : Type
      @attr_index >= 0 ? Type::ATTRIBUTE : @node_type
    end

    # Returns the qualified name of the current node: the element or
    # attribute name, the PI target, the DOCTYPE root name or the entity
    # name; `#text`, `#cdata-section` or `#comment` for character nodes.
    def name : String
      if @attr_index >= 0
        return @names[@attrs[@attr_index].name_id]
      end
      case @node_type
      when .text?, .significant_whitespace?
        "#text"
      when .cdata?
        "#cdata-section"
      when .comment?
        "#comment"
      when .none?
        ""
      else
        @names[@name_id]
      end
    end

    # Returns the local part of the current element or attribute name (the
    # same as `name` for other nodes).
    def local_name : String
      return name unless named_by_qname?
      @names[@names.local_id(current_name_id)]
    end

    # Returns the namespace prefix of the current element or attribute, or
    # nil when it has none.
    def prefix : String?
      return unless named_by_qname?
      prefix_id = @names.prefix_id(current_name_id)
      prefix_id == NameTable::EMPTY_ID ? nil : @names[prefix_id]
    end

    # Returns the namespace URI of the current element or attribute, or nil
    # when it is in no namespace.
    def namespace_uri : String?
      return unless named_by_qname?
      uri_id = @attr_index >= 0 ? @attrs[@attr_index].namespace_uri_id : @namespace_uri_id
      uri_id == NameTable::EMPTY_ID ? nil : @names[uri_id]
    end

    private def named_by_qname? : Bool
      @attr_index >= 0 || @node_type.element? || @node_type.end_element?
    end

    # Returns the text of the current node: character data, comment text,
    # PI data, or the current attribute's normalized value. Returns an empty
    # string for other node types.
    def value : String
      String.new(value_bytes)
    end

    # Returns the depth of the current node (the root element is at 0).
    def depth : Int32
      @attr_index >= 0 ? @event_depth + 1 : @event_depth
    end

    # Returns true when the current element was written `<name/>`.
    def empty_element? : Bool
      @node_type.element? && @empty_element
    end

    # Returns true when the current element has attributes (namespace
    # declarations count, as in libxml2).
    def has_attributes? : Bool
      @node_type.element? && !@attrs.empty?
    end

    # Returns the number of attributes on the current element.
    def attributes_count : Int32
      @node_type.element? ? @attrs.size : 0
    end

    # Moves to the first attribute of the current element.
    def move_to_first_attribute : Bool
      return false if !@node_type.element? || @attrs.empty?
      @attr_index = 0
      true
    end

    # Moves to the next attribute of the current element.
    def move_to_next_attribute : Bool
      return false unless @attr_index >= 0 && @attr_index + 1 < @attrs.size
      @attr_index += 1
      true
    end

    # Moves to the attribute named *name* (its qualified name).
    def move_to_attribute(name : String) : Bool
      index = attribute_index(name)
      return false if index < 0
      @attr_index = index
      true
    end

    # Moves from an attribute back to its element.
    def move_to_element : Bool
      return false if @attr_index < 0
      @attr_index = -1
      true
    end

    # Returns the value of the attribute named *name* on the current element.
    # Raises `KeyError` when it is missing.
    def [](name : String) : String
      self[name]? || raise KeyError.new("Missing attribute: #{name}")
    end

    # Returns the value of the attribute named *name*, or nil.
    def []?(name : String) : String?
      index = attribute_index(name)
      return if index < 0
      String.new(attribute_value_bytes(@attrs[index]))
    end

    # Skips the current node's subtree and moves to the node after it.
    def next : Bool
      skip_subtree
      read
    end

    # Moves to the next sibling of the current node. Returns false when the
    # parent ends first.
    def next_sibling : Bool
      start_depth = @event_depth
      while self.next
        return false if @event_depth < start_depth
        return true if @event_depth == start_depth && !@node_type.end_element?
        return false if @event_depth == start_depth
      end
      false
    end

    # Parses the current element's subtree into a new `Mica::XML::Document`
    # and returns that subtree's element.
    #
    # NOTE: Unlike libxml2, the reader streams, so expanding consumes the
    # subtree: afterwards the reader sits on the element's END_ELEMENT and
    # the next `read` moves past it.
    def expand : Node
      unless @node_type.element?
        raise Error.new("Reader#expand needs the reader on an element, not #{@node_type}")
      end
      document = Document.new(@names)
      document.build_subtree_from(self)
      document.first_element_child || raise Error.new("Reader#expand produced no element")
    end

    # Returns the markup of the current element's children. Consumes the
    # subtree like `expand`.
    def read_inner_xml : String
      return "" unless @node_type.element?
      element = expand
      String.build do |io|
        element.children.each(&.to_xml(io, indent: 0))
      end
    end

    # Returns the markup of the current element and its children. Consumes
    # the subtree like `expand`.
    def read_outer_xml : String
      return "" unless @node_type.element?
      expand.to_xml(indent: 0)
    end

    # Returns the line of the current read position (1-based).
    def line_number : Int32
      error_position.line
    end

    # Returns the column of the current read position (1-based, characters).
    def column_number : Int32
      error_position.column
    end

    # Returns the current read position (line, column and byte offset).
    def position : Core::Position
      error_position
    end

    # Returns the public identifier of the DOCTYPE, if any.
    def public_id : String?
      @dtd.public_id
    end

    # Returns the system identifier of the DOCTYPE, if any. It is never
    # fetched.
    def system_id : String?
      @dtd.system_id
    end

    # Returns the raw internal DTD subset, if any.
    def internal_subset : String?
      @dtd.internal_subset
    end

    # :nodoc:
    def current_name_id : Int32
      @attr_index >= 0 ? @attrs[@attr_index].name_id : @name_id
    end

    # :nodoc:
    def event_name_id : Int32
      @name_id
    end

    # :nodoc:
    def event_namespace_uri_id : Int32
      @namespace_uri_id
    end

    # :nodoc:
    def event_depth : Int32
      @event_depth
    end

    # :nodoc:
    def event_type : Type
      @node_type
    end

    # :nodoc:
    def event_attributes : Array(AttributeSlot)
      @attrs
    end

    # :nodoc:
    def value_bytes : Bytes
      if @attr_index >= 0
        return attribute_value_bytes(@attrs[@attr_index])
      end
      return Bytes.empty if @value_size == 0
      if @value_in_scratch
        @scratch[@value_start, @value_size]
      else
        @buffer[@mark + @value_start, @value_size]
      end
    end

    # :nodoc:
    def attribute_value_bytes(slot : AttributeSlot) : Bytes
      return Bytes.empty if slot.value_size == 0
      if slot.in_scratch
        @scratch[slot.value_start, slot.value_size]
      else
        @buffer[@mark + slot.value_start, slot.value_size]
      end
    end

    # :nodoc:
    #
    # Charges *count* operations of work done on this reader's behalf (the
    # DOM builder uses it) and raises when the budget or deadline trips.
    @[AlwaysInline]
    def charge(count : Int) : Nil
      work_limit_reached if @meter.charge(count)
    end

    # :nodoc:
    #
    # Marks the current element as consumed after `expand`.
    def finish_expand(name_id : Int32, namespace_uri_id : Int32, depth : Int32) : Nil
      @node_type = Type::END_ELEMENT
      @name_id = name_id
      @namespace_uri_id = namespace_uri_id
      @event_depth = depth
      @attrs.clear
      @value_size = 0
    end

    private def attribute_index(name : String) : Int32
      return -1 unless @node_type.element?
      id = @names.lookup(name.to_slice)
      return -1 if id < 0
      find_attribute_slot(id) || -1
    end

    private def skip_subtree : Nil
      @attr_index = -1
      return if !@node_type.element? || @empty_element
      target = @event_depth
      while read
        break if @node_type.end_element? && @event_depth == target
      end
    end

    private def work_limit_reached : Nil
      verdict = @meter.verdict
      return if verdict.within?
      position = error_position
      message = @meter.describe(verdict)
      if verdict.deadline_exceeded?
        raise DeadlineExceededError.new(message, position, @meter.elapsed)
      end
      raise WorkBudgetExceededError.new(message, position, @meter.operations, @meter.allowance)
    end

    # Charges the bytes scanned since the token mark plus fixed per-token
    # work and any name-table probes since the last charge.
    @[AlwaysInline]
    private def charge_token : Nil
      probes = @names.probes
      charge(@pos - @mark - @token_precharged + TOKEN_OPERATIONS + (probes - @charged_probes))
      @token_precharged = 0
      @charged_probes = probes
    end

    # Core::ByteInput hooks.

    private def input_token_limit : Int32
      @options.max_token_bytes
    end

    private def input_size_limit : Int64?
      @options.max_input_bytes
    end

    private def input_limit_error(message : String) : NoReturn
      limit_error(message)
    end

    private def discarding_input(keep : Int32) : Nil
      fold_discarded_columns(@buffer, keep, @base_offset)
    end

    private def input_received(count : Int32) : Nil
      @meter.add_units(count)
    end
  end
end

require "./reader/source"
require "./reader/scanning"
require "./reader/prolog"
require "./reader/content"
require "./reader/references"
require "./reader/namespaces"
require "./reader/dtd_parser"
