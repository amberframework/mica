module Mica::Form
  # Builds a nested `Value` from form pairs whose names use bracket keys
  # (`user[address][city]`, `tags[]`, `items[0][name]`) or dot keys
  # (`user.address.city`).
  #
  # No standard defines bracket keys. Mica follows the Rack convention
  # with this explicit grammar (the requirement ids are in
  # `spec/requirements/form.tsv`):
  #
  # ```text
  # key      = head *segment
  # head     = 1*( any byte except "[" )
  # segment  = "[" *( any byte except "[" and "]" ) "]"
  # ```
  #
  # - A key without `[` is one hash key, or, when `Options#dot_notation?`
  #   is on and the key holds a `.`, the hash keys between its dots
  #   (`a.b.c`; every part must be non-empty). Dot parts are always hash
  #   keys, never array indices.
  # - A key with `[` must be a non-empty head followed only by complete
  #   segments; anything else (`[a]`, `a[b`, `a[b]c`, `a[b[c]]`) raises
  #   `Mica::Form::KeySyntaxError`. Dots inside a bracketed key are
  #   ordinary bytes.
  # - A segment of decimal digits in canonical form (`0`, or no leading
  #   zero) is an array index; it must be at most `Limits#max_array_index`.
  #   Any other non-empty segment (including `007`) is a hash key.
  # - An empty segment (`[]`) appends. As the last segment it appends the
  #   value. Before a hash key it follows Rack: the key continues the last
  #   element of the array when that element is a hash that does not yet
  #   hold the rest of the key, and starts a new hash otherwise, so
  #   `a[][x]=1&a[][y]=2&a[][x]=3` gives `[{x: 1, y: 2}, {x: 3}]`. Before
  #   an index or another append it starts a new array.
  # - Arrays are sparse while they are built: `a[999]` stores one entry.
  #   The result is dense, with nil `Value`s in the gaps; those slots count
  #   toward `Limits#max_array_slots`.
  # - A key that needs a hash where an array or a string already is, an
  #   array where a hash or a string is, or a string where a hash or an
  #   array is, raises `Mica::Form::KeyConflictError`. Nothing is silently
  #   skipped.
  # - The same string path twice keeps the last value by default (the
  #   hidden-field idiom for checkboxes sends `on=0&on=1`);
  #   `DuplicateLeaves::Reject` raises `KeyConflictError` instead.
  #
  # - Names and values must be valid UTF-8. Pairs from `Pairs.parse`
  #   already are; for pairs built in code, `invalid_utf8:` (see
  #   `InvalidUTF8Handling`) chooses between `:reject` (the default, which
  #   raises `Mica::EncodingError`) and `:replace_like_browsers` (each
  #   invalid sequence becomes U+FFFD). The result's
  #   `Value#has_replaced_invalid_bytes?` is true when any pair that
  #   reached that node was altered, here or by `Pairs.parse`.
  #
  # Every error carries the byte offset of the offending pair.
  #
  # ```
  # pairs = Mica::Form::Pairs.parse("user[name]=Ada&user[langs][]=en&user[langs][]=fr", limits: Mica::Form::Limits::REQUEST_BODY)
  # value = Mica::Form::NestedKeys.build(pairs, limits: Mica::Form::Limits::REQUEST_BODY)
  # value["user"]["langs"].as_a.map(&.as_s) # => ["en", "fr"]
  # ```
  #
  # Work is linear in the bytes of the keys plus the array slots of the
  # result: each segment is one hash or array lookup, and the Rack append
  # check walks only the segments up to the next append.
  class NestedKeys
    # What a second value for the same string path does.
    enum DuplicateLeaves
      # The later value replaces the earlier one.
      LastWins
      # Raises `Mica::Form::KeyConflictError`.
      Reject
    end

    # Switches for the key grammar.
    record Options, dot_notation : Bool = true, duplicate_leaves : DuplicateLeaves = DuplicateLeaves::LastWins do
      # Returns true when keys without brackets split at dots.
      def dot_notation? : Bool
        @dot_notation
      end
    end

    # Operations charged for each node created (the node and its
    # conversion into a `Value`).
    NODE_OPERATIONS = 2

    # One parsed key segment.
    private enum SegmentKind
      Name
      Index
      Append
    end

    private record Segment, kind : SegmentKind, name : String = "", index : Int32 = 0

    private abstract class Node
      # True when a pair whose invalid UTF-8 was replaced reached this node.
      property? has_replaced_invalid_bytes = false
    end

    private class LeafNode < Node
      property text : String

      def initialize(@text : String)
      end
    end

    private class HashNode < Node
      getter children = {} of String => Node
    end

    private class ArrayNode < Node
      getter slots = {} of Int32 => Node
      property size = 0
    end

    # Returns the nested value of *pairs*. *meter* lets the build share a
    # work budget (for example with the `Pairs.parse` that produced the
    # pairs); without it the build starts a meter from
    # `limits.work_budget` and counts the bytes of every name and value as
    # units of input. *invalid_utf8* applies to names and values that are
    # not valid UTF-8 (see `InvalidUTF8Handling`).
    def self.build(pairs : Enumerable(Pair), *, limits : Limits, meter : Core::WorkMeter? = nil, options : Options = Options.new,
                   invalid_utf8 : InvalidUTF8Handling = InvalidUTF8Handling::Reject) : Value
      builder = new(limits: limits, meter: meter, options: options, invalid_utf8: invalid_utf8)
      pairs.each { |pair| builder.add(pair) }
      builder.finish
    end

    def initialize(*, @limits : Limits, meter : Core::WorkMeter? = nil, @options : Options = Options.new,
                   @invalid_utf8 : InvalidUTF8Handling = InvalidUTF8Handling::Reject)
      @counts_units = meter.nil?
      @meter = meter || Core::WorkMeter.new(@limits.work_budget)
      @root = HashNode.new
      @pair_count = 0
      @array_slots = 0_i64
      @input_bytes = 0_i64
      @finished = false
      @failed = false
    end

    # Adds one pair to the structure. The bytes of every name and value
    # added count toward `Limits#max_input_bytes` (decoded pairs from
    # `Pairs` are never longer than their input, so a shared parse trips
    # the limit in `Pairs` first). Limits count bytes before replacement:
    # a pair from `Pairs.parse` with replacements counts its
    # `Pair#byte_size_before_replacement`, and every other pair counts
    # every byte it holds. Raises
    # `Mica::EncodingError` for invalid UTF-8 under `invalid_utf8: :reject`,
    # and `KeySyntaxError`, `KeyConflictError` or `Mica::LimitExceededError`
    # (all with the pair's offset) when the pair cannot be added. A builder that raised may hold
    # part of that pair, so it refuses further use with `ArgumentError`.
    def add(pair : Pair) : Nil
      raise ArgumentError.new("NestedKeys#add after finish") if @finished
      raise ArgumentError.new("NestedKeys#add after a failed add") if @failed
      @failed = true
      @pair_count += 1
      if @pair_count > @limits.max_pairs
        raise LimitExceededError.new("Form has more than max_pairs (#{@limits.max_pairs}) pairs", position(pair))
      end
      pair = with_counted_and_valid_bytes(pair)
      segments = parse_key(pair)
      insert(segments, pair)
      @failed = false
    end

    # Returns the finished structure. Further `add` calls raise
    # `ArgumentError`. Runs iteratively, so deep keys need no deep stack.
    def finish : Value
      raise ArgumentError.new("NestedKeys#finish after a failed add") if @failed
      @finished = true
      result = {} of String => Value
      stack = [] of {Node, Hash(String, Value) | Array(Value)}
      stack << {@root, result}
      while entry = stack.pop?
        node, target = entry
        if node.is_a?(HashNode) && target.is_a?(Hash(String, Value))
          node.children.each { |key, child| target[key] = convert(child, stack) }
        elsif node.is_a?(ArrayNode) && target.is_a?(Array(Value))
          node.slots.each { |index, child| target[index] = convert(child, stack) }
        end
      end
      @meter.enforce_deadline { Core::Position.new(0_i64) }
      Value.new(result, has_replaced_invalid_bytes: @root.has_replaced_invalid_bytes?)
    end

    private def convert(node : Node, stack : Array({Node, Hash(String, Value) | Array(Value)})) : Value
      replaced = node.has_replaced_invalid_bytes?
      if node.is_a?(LeafNode)
        Value.new(node.text, has_replaced_invalid_bytes: replaced)
      elsif node.is_a?(HashNode)
        hash = {} of String => Value
        stack << {node, hash}
        Value.new(hash, has_replaced_invalid_bytes: replaced)
      elsif node.is_a?(ArrayNode)
        array = Array(Value).new(node.size, Value.new(nil))
        stack << {node, array}
        Value.new(array, has_replaced_invalid_bytes: replaced)
      else
        raise ArgumentError.new("Unknown form node #{node.class}")
      end
    end

    # Splits the pair's name into segments (see the grammar above).
    private def parse_key(pair : Pair) : Array(Segment)
      key = pair.field_name
      bytes = key.to_slice
      # Finding the brackets reads the key at most twice.
      charge(2_i64 * bytes.size + 1, pair)
      bracket = bytes.index(0x5B_u8)
      return parse_plain_key(key, pair) unless bracket
      syntax_error(pair, "starts with '['") if bracket == 0
      segments = [Segment.new(SegmentKind::Name, key.byte_slice(0, bracket))]
      index = bracket
      while index < bytes.size
        syntax_error(pair, "has bytes after ']' that do not start a segment") unless bytes[index] == 0x5B
        close = bytes.index(0x5D_u8, index + 1)
        syntax_error(pair, "has an unclosed '['") unless close
        inner = bytes[index + 1, close - index - 1]
        syntax_error(pair, "has '[' inside a segment") if inner.index(0x5B_u8)
        segments << segment_for(inner, pair)
        check_depth(segments.size, pair)
        index = close + 1
      end
      segments
    end

    private def parse_plain_key(key : String, pair : Pair) : Array(Segment)
      return [Segment.new(SegmentKind::Name, key)] unless @options.dot_notation? && key.includes?('.')
      segments = [] of Segment
      key.split('.') do |part|
        syntax_error(pair, "has an empty part between dots") if part.empty?
        segments << Segment.new(SegmentKind::Name, part)
        check_depth(segments.size, pair)
      end
      segments
    end

    private def segment_for(inner : Bytes, pair : Pair) : Segment
      return Segment.new(SegmentKind::Append) if inner.empty?
      if index = canonical_index(inner, pair)
        Segment.new(SegmentKind::Index, index: index)
      else
        Segment.new(SegmentKind::Name, String.new(inner))
      end
    end

    # Returns the array index *digits* names, or nil when it is not a
    # canonical decimal number. Raises the max_array_index error for a
    # larger index, reading at most one digit past the limit's length.
    private def canonical_index(digits : Bytes, pair : Pair) : Int32?
      return unless digits.all? { |byte| byte >= 0x30 && byte <= 0x39 }
      return if digits.size > 1 && digits[0] == 0x30
      value = 0_i64
      digits.each do |byte|
        value = value * 10 + (byte - 0x30)
        array_index_exceeded(pair) if value > @limits.max_array_index
      end
      value.to_i32
    end

    # The bytes *pair* counts toward `max_input_bytes`: the size of its name
    # and value before replacement, so replacement never trips a limit the
    # original bytes would not. Only Mica's decoding can set that size
    # (see `Pair`); any other pair counts every byte it holds.
    private def bytes_before_replacement(pair : Pair) : Int64
      pair.byte_size_before_replacement || pair.field_name.bytesize.to_i64 + pair.field_value.bytesize
    end

    # Counts *pair* toward `max_input_bytes` and the work units, then
    # returns it with valid UTF-8 (see `with_valid_utf8`).
    private def with_counted_and_valid_bytes(pair : Pair) : Pair
      pair_bytes = bytes_before_replacement(pair)
      @input_bytes += pair_bytes
      if @input_bytes > @limits.max_input_bytes
        raise LimitExceededError.new("Form pairs exceed max_input_bytes (#{@limits.max_input_bytes})", position(pair))
      end
      @meter.add_units(pair_bytes) if @counts_units
      with_valid_utf8(pair)
    end

    # Returns *pair* when its name and value are valid UTF-8. Otherwise
    # raises `Mica::EncodingError` under `:reject`, or returns a copy with
    # each invalid sequence replaced by U+FFFD and marked as replaced.
    private def with_valid_utf8(pair : Pair) : Pair
      name_bytes = pair.field_name.to_slice
      value_bytes = pair.field_value.to_slice
      charge(name_bytes.size.to_i64 + value_bytes.size, pair)
      invalid_in_name = Core::UTF8.first_invalid_offset(name_bytes)
      invalid_in_value = Core::UTF8.first_invalid_offset(value_bytes)
      return pair unless invalid_in_name || invalid_in_value
      if @invalid_utf8.reject?
        part, offset = invalid_in_name ? {"name", invalid_in_name} : {"value", invalid_in_value || 0}
        raise EncodingError.new(
          "Invalid UTF-8 in form #{part} at byte #{offset} of the #{part}; #{INVALID_UTF8_REJECTION_HINT}",
          position(pair))
      end
      charge(Pairs::REPLACEMENT_PASSES.to_i64 * (name_bytes.size + value_bytes.size), pair)
      Pair.new(
        Core::UTF8.replace_invalid_sequences_like_browsers(name_bytes),
        Core::UTF8.replace_invalid_sequences_like_browsers(value_bytes),
        pair.byte_offset,
        byte_size_before_replacement: name_bytes.size.to_i64 + value_bytes.size,
        seal: REPLACEMENT_SEAL)
    end

    private def insert(segments : Array(Segment), pair : Pair) : Nil
      container : Node = @root
      container.has_replaced_invalid_bytes = true if pair.has_replaced_invalid_bytes?
      last = segments.size - 1
      segments.each_with_index do |segment, position|
        following = position < last ? segments[position + 1] : nil
        charge(1 + segment.name.bytesize, pair)
        container = if following
                      step(container, segment, following, segments, position, pair)
                    else
                      store(container, segment, pair)
                      container
                    end
        container.has_replaced_invalid_bytes = true if pair.has_replaced_invalid_bytes?
      end
    end

    # Returns the container *segment* leads to inside *container*, creating
    # it with the kind *following* needs.
    private def step(container : Node, segment : Segment, following : Segment, segments : Array(Segment), position : Int32, pair : Pair) : Node
      wants_hash = following.kind.name?
      if container.is_a?(HashNode)
        existing = container.children[segment.name]?
        return checked_container(existing, wants_hash, pair) if existing
        container.children[segment.name] = new_container(wants_hash, pair)
      elsif container.is_a?(ArrayNode)
        if segment.kind.append? && wants_hash
          if continued = continue_last_hash(container, segments, position, pair)
            return continued
          end
        end
        index = segment.kind.append? ? next_index(container, pair) : segment.index
        existing = container.slots[index]?
        return checked_container(existing, wants_hash, pair) if existing
        child = new_container(wants_hash, pair)
        place(container, index, child, pair)
        child
      else
        raise ArgumentError.new("Unknown form container #{container.class}")
      end
    end

    # Stores the pair's value at the final *segment* of *container*.
    private def store(container : Node, segment : Segment, pair : Pair) : Nil
      if container.is_a?(HashNode)
        existing = container.children[segment.name]?
        if existing
          replace_leaf(existing, pair)
        else
          charge(NODE_OPERATIONS, pair)
          container.children[segment.name] = new_leaf(pair)
        end
      elsif container.is_a?(ArrayNode)
        index = segment.kind.append? ? next_index(container, pair) : segment.index
        if existing = container.slots[index]?
          replace_leaf(existing, pair)
        else
          charge(NODE_OPERATIONS, pair)
          place(container, index, new_leaf(pair), pair)
        end
      end
    end

    private def replace_leaf(existing : Node, pair : Pair) : Nil
      conflict(pair, "assigns a value where #{kind_name(existing)} already is") unless existing.is_a?(LeafNode)
      conflict(pair, "repeats a key that already has a value") if @options.duplicate_leaves.reject?
      existing.text = pair.field_value
      existing.has_replaced_invalid_bytes = true if pair.has_replaced_invalid_bytes?
    end

    private def new_leaf(pair : Pair) : LeafNode
      leaf = LeafNode.new(pair.field_value)
      leaf.has_replaced_invalid_bytes = pair.has_replaced_invalid_bytes?
      leaf
    end

    # Applies the Rack rule for `[]` before a hash key: returns the last
    # element of *array* when it is a hash that does not yet hold the rest
    # of the key (up to the next append), or nil to start a new hash.
    private def continue_last_hash(array : ArrayNode, segments : Array(Segment), position : Int32, pair : Pair) : Node?
      return if array.size == 0
      last = array.slots[array.size - 1]?
      return unless last.is_a?(HashNode)
      node : Node = last
      index = position + 1
      while index < segments.size
        segment = segments[index]
        return last if segment.kind.append?
        charge(1 + segment.name.bytesize, pair)
        child = if node.is_a?(HashNode) && segment.kind.name?
                  node.children[segment.name]?
                elsif node.is_a?(ArrayNode) && segment.kind.index?
                  node.slots[segment.index]?
                end
        return last unless child
        node = child
        index += 1
      end
      nil
    end

    private def checked_container(existing : Node, wants_hash : Bool, pair : Pair) : Node
      matches = wants_hash ? existing.is_a?(HashNode) : existing.is_a?(ArrayNode)
      return existing if matches
      conflict(pair, "needs #{wants_hash ? "a hash" : "an array"} where #{kind_name(existing)} already is")
    end

    private def new_container(wants_hash : Bool, pair : Pair) : Node
      charge(NODE_OPERATIONS, pair)
      wants_hash ? HashNode.new : ArrayNode.new
    end

    private def next_index(array : ArrayNode, pair : Pair) : Int32
      array_index_exceeded(pair) if array.size > @limits.max_array_index
      array.size
    end

    # Puts *child* at *index*, growing the array's size and counting the
    # slots it adds against `max_array_slots` and the work budget.
    private def place(array : ArrayNode, index : Int32, child : Node, pair : Pair) : Nil
      if index >= array.size
        # Int64 arithmetic: an index of Int32::MAX must trip the slot limit,
        # not overflow.
        added = index.to_i64 + 1 - array.size
        @array_slots += added
        if @array_slots > @limits.max_array_slots
          raise LimitExceededError.new("Form arrays exceed max_array_slots (#{@limits.max_array_slots})", position(pair))
        end
        charge(added, pair)
        array.size = index + 1
      end
      array.slots[index] = child
    end

    private def check_depth(depth : Int32, pair : Pair) : Nil
      return if depth <= @limits.max_key_depth
      raise LimitExceededError.new(
        "Form key #{Core.quote(pair.field_name)} has more than max_key_depth (#{@limits.max_key_depth}) segments",
        position(pair))
    end

    private def array_index_exceeded(pair : Pair) : NoReturn
      raise LimitExceededError.new(
        "Form key #{Core.quote(pair.field_name)} names an array index above max_array_index (#{@limits.max_array_index})",
        position(pair))
    end

    private def syntax_error(pair : Pair, problem : String) : NoReturn
      raise KeySyntaxError.new("Form key #{Core.quote(pair.field_name)} #{problem}", position(pair))
    end

    private def conflict(pair : Pair, problem : String) : NoReturn
      raise KeyConflictError.new("Form key #{Core.quote(pair.field_name)} #{problem}", position(pair))
    end

    private def kind_name(node : Node) : String
      if node.is_a?(LeafNode)
        "a string"
      elsif node.is_a?(HashNode)
        "a hash"
      else
        "an array"
      end
    end

    private def charge(count : Int, pair : Pair) : Nil
      Metering.charge(@meter, count) { position(pair) }
    end

    private def position(pair : Pair) : Core::Position
      Core::Position.new(pair.byte_offset)
    end
  end
end
