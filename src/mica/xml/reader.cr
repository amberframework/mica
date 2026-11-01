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
    include Core::TextInput
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
    # An element whose end tag is still to come: its name, namespace, the
    # binding stack size before its declarations, and the entity nesting
    # level it started in.
    record OpenElement,
      name_id : Int32,
      namespace_uri_id : Int32,
      binding_mark : Int32,
      entity_level : Int32

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
    @normalized_name_ids = Set(Int32).new

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
    @open_elements = [] of OpenElement
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

    # Name-table operations already charged to the meter.
    @charged_name_operations = 0_i64

    # Interned names used by the scanner.
    @xmlns_id : Int32
    @xml_id : Int32
    @xml_namespace_id : Int32
    @xmlns_namespace_id : Int32
    @predefined_ids : StaticArray(Int32, 5)

    # Creates a reader over *string*. The string's bytes are read in place.
    def self.new(string : String, options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil, *, name_seed : UInt32? = nil) : self
      new(string.to_slice, options, meter, name_seed: name_seed)
    end

    # Creates a reader over *bytes* (UTF-8, or UTF-16 with a byte order
    # mark). The bytes are read in place and must not change while the
    # reader is in use. *meter* lets several operations share one budget;
    # without it the reader starts a meter from `options.work_budget`.
    #
    # *name_seed* (`:nodoc:`, for reproducible tests and fuzzing) fixes the
    # name table's hash seed; leave it nil in production so each reader
    # draws a random seed.
    def initialize(bytes : Bytes, @options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil, *, name_seed : UInt32? = nil)
      @meter = meter || Core::WorkMeter.new(@options.work_budget)
      @names = NameTable.new(name_seed)
      @names.before_rebuild = ->(work : Int64) { charge(work) }
      @dtd = DTD.new
      @xmlns_id = @names.intern("xmlns")
      @xml_id = @names.intern("xml")
      @xml_namespace_id = @names.intern(XML_NAMESPACE)
      @xmlns_namespace_id = @names.intern(XMLNS_NAMESPACE)
      @predefined_ids = StaticArray[@names.intern("lt"), @names.intern("gt"), @names.intern("amp"), @names.intern("apos"), @names.intern("quot")]
      setup_bytes(bytes)
    end

    # Creates a streaming reader over *io*.
    def initialize(io : IO, @options : ParserOptions = ParserOptions.default, meter : Core::WorkMeter? = nil, *, name_seed : UInt32? = nil)
      @meter = meter || Core::WorkMeter.new(@options.work_budget)
      @names = NameTable.new(name_seed)
      @names.before_rebuild = ->(work : Int64) { charge(work) }
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

    # Replaces the work meter with a fresh one for *budget*: the operation
    # count and the deadline start again from now. Long-lived streams (a
    # protocol session over a socket) call this between messages instead of
    # disabling the budget.
    def renew_meter(budget : Core::WorkBudget = @options.work_budget) : Core::WorkMeter
      meter = Core::WorkMeter.new(budget)
      # Bytes already buffered but not yet consumed arrived under the old
      # meter; the new one gets their units so it can afford to scan them.
      meter.add_units(@limit - @pos)
      @meter = meter
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
      produced = advance
      verify_normalization if produced && normalization_checked?
      produced
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
    #
    # Without namespace processing a name is one unit: `local_name` is the
    # whole name and `prefix` is nil.
    def local_name : String
      return name unless named_by_qname? && @options.namespace_aware?
      @names[@names.local_id(current_name_id)]
    end

    # Returns the namespace prefix of the current element or attribute, or
    # nil when it has none.
    def prefix : String?
      return unless named_by_qname? && @options.namespace_aware?
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
      bytes = value_bytes
      # The copy is charged, so repeated reads draw on the budget.
      charge(bytes.size + 1)
      String.new(bytes)
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
      self[name]? || raise KeyError.new("Missing attribute: #{Core.quote(name)}")
    end

    # Returns the value of the attribute named *name*, or nil.
    def []?(name : String) : String?
      index = attribute_index(name)
      return if index < 0
      bytes = attribute_value_bytes(@attrs[index])
      charge(bytes.size + 1)
      String.new(bytes)
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
      document = Document.new(@names, shared_names: true)
      document.build_subtree_from(self)
      document.first_element_child || raise Error.new("Reader#expand produced no element")
    end

    # Returns the markup of the current element's children. Consumes the
    # subtree like `expand`.
    def read_inner_xml : String
      return "" unless @node_type.element?
      element = expand
      String.build do |io|
        writer = MeteredWriter.new(self, io)
        # Each link to a child is charged before it is followed (the first
        # here, each next one after the child before it); no array of all
        # children is built.
        charge(1)
        element.each_child_node do |child|
          child.to_xml(writer, indent: 0)
          charge(1)
        end
      end
    end

    # Returns the markup of the current element and its children. Consumes
    # the subtree like `expand`.
    def read_outer_xml : String
      return "" unless @node_type.element?
      element = expand
      String.build do |io|
        element.to_xml(MeteredWriter.new(self, io), indent: 0)
      end
    end

    # Passes writes to *io*, charging each one's bytes to the reader first,
    # so serializing an expanded subtree stops when the budget or the
    # deadline runs out.
    private class MeteredWriter < IO
      def initialize(@reader : Reader, @io : IO)
      end

      def read(slice : Bytes) : Int32
        raise Error.new("MeteredWriter is write-only")
      end

      def write(slice : Bytes) : Nil
        @reader.charge(slice.size)
        @io.write(slice)
      end
    end

    # Returns the line of the current read position (1-based).
    def line_number : Int32
      position.line
    end

    # Returns the column of the current read position (1-based, characters).
    def column_number : Int32
      position.column
    end

    # Returns the current read position (line, column and byte offset).
    # Asking after every event stays linear overall (see
    # `Core::LineTracking`); the counting is charged to the work meter.
    def position : Core::Position
      charged = 0_i64
      position = error_position do |count|
        charge(count)
        charged += count
      end
      steps = @column_steps + @offset_steps
      charge(steps - @charged_position_steps - charged + 1)
      @charged_position_steps = steps
      position
    end

    @charged_position_steps = 0_i64

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
    #
    # Charges the name-table work done since the last charge (the DOM
    # builder settles an expansion with it).
    def settle_name_operations : Nil
      charge(take_name_operations)
    end

    # :nodoc:
    #
    # The binding stack size before the current start tag's declarations:
    # bindings below it were declared by the tag's ancestors.
    def event_binding_mark : Int32
      return @binding_prefixes.size unless @node_type.element?
      @empty_element ? @pending_binding_mark : @open_elements.last.binding_mark
    end

    # :nodoc:
    #
    # Returns the URI id that *prefix_id* is bound to here when that binding
    # lies below *mark* (an ancestor of the start tag that set *mark*
    # declared it), or -1.
    def inherited_binding_uri(prefix_id : Int32, mark : Int32) : Int32
      binding = prefix_id < @innermost_binding.size ? @innermost_binding[prefix_id] : -1
      binding >= 0 && binding < mark ? @binding_uris[binding] : -1
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
      # The caller's name is hashed and compared (two passes): charged
      # before; probes beyond that after.
      prepaid = 2_i64 * name.bytesize + 2
      charge(prepaid)
      lookups = @names.lookup_operations
      id = @names.lookup(name.to_slice)
      charge(Math.max(@names.lookup_operations - lookups - prepaid, 0_i64))
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
      @meter.enforce { error_position }
    end

    # Charges the bytes scanned since the token mark plus fixed per-token
    # work and the name-table work since the last charge.
    @[AlwaysInline]
    private def charge_token : Nil
      scanned = @pos - @mark - @token_precharged
      charge(scanned.to_i64 + discard_prepay(scanned) + TOKEN_OPERATIONS + take_name_operations + @token_operations)
      @token_precharged = 0
      @token_operations = 0_i64
    end

    # Core::ByteInput hooks.

    private def input_token_limit : Int32
      @options.max_token_bytes
    end

    private def input_size_limit : Int64?
      @options.max_input_bytes
    end

    # Points the error at the first byte past the limit: the position is
    # advanced from the scanner's over the buffered bytes in between (that
    # walk is charged first). A CR whose line end was still being completed
    # when the refill came (its LF may be among the new bytes) is walked
    # again from the CR, so CR LF counts as one line end.
    # Compaction and growth copy each byte a bounded number of times; the
    # copy is charged before it happens.
    private def moving_input(count : Int64) : Nil
      charge(count)
    end

    private def input_size_exceeded(message : String, excess_index : Int32) : NoReturn
      charge_scanned_before_error
      charge(excess_index - @pos)
      start = error_position
      from = @pos
      if pending_carriage_return?
        start = Core::Position.new(start.byte_offset, start.line, start.column - 1)
        from = @pos - 1
      end
      raise LimitExceededError.new(message, position_after(start, from, excess_index))
    end

    # True when the byte before the scanner is a CR in the document whose
    # line break is not yet recorded.
    private def pending_carriage_return? : Bool
      @in_document_source && @pos > 0 && @buffer[@pos - 1] == 0x0D && @line_start != @base_offset + @pos
    end

    private def input_limit_error(message : String) : NoReturn
      limit_error(message)
    end

    # The folds below examine each discarded byte once; their work was
    # prepaid when a token scanned those bytes (see `discard_prepay`).
    private def discarding_input(keep : Int32) : Nil
      fold_discarded_columns(@buffer, keep, @base_offset)
      account_transcoded_discard(keep)
    end

    # A transcoder may read the source several times for one refill: the
    # deadline is checked after each of those reads too.
    private def source_read_returned : Nil
      @meter.enforce_deadline { error_position }
    end

    # New input raises the allowance; a refill is also where the reader may
    # have waited on its IO, so the deadline is checked here too.
    private def input_received(count : Int32) : Nil
      @meter.add_units(count)
      @meter.enforce_deadline { error_position }
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
require "./reader/normalization"
