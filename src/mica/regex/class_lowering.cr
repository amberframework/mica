module Mica::Regex
  # Lowers syntax-tree classes and case-folded literals to `CodePointSet`s,
  # with case folding chosen per dialect:
  #
  # - **Crystal (PCRE2):** under `IgnoreCase`, only literal characters and
  #   ranges are closed over their simple case folding orbits; `\d`, `\w`,
  #   `\s`, `\p{...}` and POSIX classes are not folded (PCRE2 turns `Lu`,
  #   `Ll` and `Lt` into `L&` instead, at parse time). `CaselessRestrict`
  #   keeps ASCII and non-ASCII characters apart. Negation applies after
  #   folding.
  # - **ECMA-262 (`u` mode):** every member of the class is closed over the
  #   orbits (`Canonicalize` is simple case folding), escapes included, so
  #   `/[\w]/iu` gains U+017F and U+212A. Negation applies after folding.
  # - **XSD:** no case-insensitive mode exists; nothing is folded.
  #
  # Sets are merged in one pass over all members (a heap of sorted range
  # streams, one per distinct member, so repeating `\p{L}` costs no more
  # merge work than writing it once), and the result is refused with
  # `CompileLimitError` naming `max_class_ranges` as soon as it would grow
  # past the limit. Every allocation is charged to the `AllocationLedger`
  # before it is made, and every heap step to the work meter with the
  # heap's depth.
  module ClassLowering
    # The bounds of each `Ast::AsciiSet`, indexed by its value. Built once
    # per process and only read (range streams walk it in place).
    private ASCII_SET_BOUNDS = Ast::AsciiSet.values.map do |ascii_set|
      bounds = [] of Int32
      ascii_set.ranges.each { |first, last| bounds << first << last }
      bounds
    end

    # Lowers *char_class* for *dialect*.
    #
    # A class of one escape or property (`\w`, `\p{L}`, `[^\d]`) that
    # case folding leaves alone lowers to a set shared by the process:
    # it is lowered once and the same set object comes back afterward, so
    # the class costs no merge and its compiled automaton (`ClassMemo`) is
    # found by the set's digest. A shared set larger than the caller's
    # `max_class_ranges` is lowered again, so the refusal is the same.
    def self.lower(char_class : Ast::CharClass, dialect : Dialect, limits : CompileLimits, ledger : AllocationLedger,
                   meter : Core::WorkMeter) : CodePointSet
      items = char_class.list_of_items
      item = items.first?
      unless items.size == 1 && item && !item.item_kind.range? && !(char_class.options.ignore_case? && dialect.ecma262?)
        return lower_written_class(char_class, dialect, limits, ledger, meter)
      end
      key = {item, char_class.negated?}
      shared = @@shared_mutex.synchronize { @@shared_sets[key]? }
      return shared if shared && shared.range_count <= limits.max_class_ranges
      set = lower_items(char_class, dialect, limits, ledger, meter)
      @@shared_mutex.synchronize { @@shared_sets[key] ||= set }
    end

    # The shared sets of single-item classes, by item and negation. There
    # are at most two per escape and property, so the table stays small.
    @@shared_mutex = Mutex.new
    @@shared_sets = {} of {Ast::ClassItem, Bool} => CodePointSet

    # The most items a class may have for its lowering to be kept in
    # `@@written_sets`, and the most classes kept there.
    WRITTEN_CLASS_ITEMS =  32
    WRITTEN_CLASSES     = 512

    # What a written class lowers from: its items, negation, whether it is
    # folded and restricted, and the dialect.
    private alias WrittenClassKey = {Array(Ast::ClassItem), Bool, Bool, Bool, Dialect}

    # Lowers a class of several items or of ranges (`[0-9a-f]`,
    # `[\w.-]`). Under `IgnoreCase` its ranges are closed over their fold
    # orbits, which reads the fold table member by member, and a pattern
    # often writes the same class many times (`[0-9a-f]{8}-[0-9a-f]{4}`),
    # so the sets of classes up to `WRITTEN_CLASS_ITEMS` items are kept
    # for the process (up to `WRITTEN_CLASSES` of them; a full table is
    # emptied and filled again, so the classes a process keeps compiling
    # stay in it). The same set object comes back for
    # the same class, so `ClassMemo` finds its automaton by identity. A
    # kept set larger than the caller's `max_class_ranges` is lowered
    # again, so the refusal is the same.
    private def self.lower_written_class(char_class : Ast::CharClass, dialect : Dialect, limits : CompileLimits,
                                         ledger : AllocationLedger, meter : Core::WorkMeter) : CodePointSet
      items = char_class.list_of_items
      return lower_items(char_class, dialect, limits, ledger, meter) if items.size > WRITTEN_CLASS_ITEMS
      options = char_class.options
      folding = options.ignore_case? && !dialect.xsd?
      restricted = folding && options.caseless_restrict? && dialect.crystal?
      key = {items, char_class.negated?, folding, restricted, dialect}
      written = @@shared_mutex.synchronize { @@written_sets[key]? }
      return written if written && written.range_count <= limits.max_class_ranges
      set = lower_items(char_class, dialect, limits, ledger, meter)
      @@shared_mutex.synchronize do
        kept = @@written_sets[key]?
        return kept if kept && kept.range_count <= limits.max_class_ranges
        @@written_sets.clear if @@written_sets.size >= WRITTEN_CLASSES
        @@written_sets[{items.dup, key[1], key[2], key[3], key[4]}] = set
      end
      set
    end

    @@written_sets = {} of WrittenClassKey => CodePointSet

    private def self.lower_items(char_class : Ast::CharClass, dialect : Dialect, limits : CompileLimits,
                                 ledger : AllocationLedger, meter : Core::WorkMeter) : CodePointSet
      ledger.charge_object(instance_sizeof(Context), "a class lowering", char_class.offset)
      context = Context.new(char_class.offset, limits, ledger, meter)
      options = char_class.options
      folding = options.ignore_case? && !dialect.xsd?
      restricted = options.caseless_restrict? && dialect.crystal?
      context.charge_array(0, 8)
      list_of_ranges = [] of {Int32, Int32}
      context.charge_array(0, 8)
      list_of_streams = [] of RangeStream
      context.charge_hash
      seen_items = Set(Ast::ClassItem).new
      char_class.list_of_items.each do |item|
        context.charge_work(1)
        if item.item_kind.range?
          context.charge_append(sizeof({Int32, Int32}))
          list_of_ranges << {item.first, item.last}
        else
          next if seen_items.includes?(item)
          context.charge_hash_entry(sizeof(Ast::ClassItem))
          seen_items << item
          context.charge_stream
          list_of_streams << RangeStream.for_item(item, ASCII_SET_BOUNDS)
        end
      end
      unless list_of_ranges.empty?
        literal_bounds = merge_ranges(list_of_ranges, context)
        context.charge_stream
        list_of_streams << RangeStream.new(literal_bounds, false)
        if folding && dialect.crystal?
          partners = fold_partners(literal_bounds, restricted, context)
          context.charge_stream
          list_of_streams << RangeStream.new(partners, false)
        end
      end
      set = union(list_of_streams, context)
      if folding && dialect.ecma262?
        partners = fold_partners(set.list_of_bounds, false, context)
        context.charge_array(2, 8)
        context.charge_stream
        context.charge_stream
        set = union([RangeStream.new(set.list_of_bounds, false), RangeStream.new(partners, false)], context)
      end
      set = complement(set, context) if char_class.negated?
      context.check_final(set.range_count)
      set
    end

    # Returns the set *literal* stands for when case folding gives it fold
    # partners in *dialect* (the code point closed over its simple case
    # folding orbit, kept within ASCII or non-ASCII under
    # `CaselessRestrict` in the Crystal dialect), or nil when it matches
    # only itself. The set is held to `max_class_ranges` like any class.
    def self.fold_literal(literal : Ast::Literal, dialect : Dialect, limits : CompileLimits,
                          ledger : AllocationLedger, meter : Core::WorkMeter) : CodePointSet?
      options = literal.options
      return nil unless options.ignore_case? && !dialect.xsd?
      code_point = literal.code_point
      restricted = options.caseless_restrict? && dialect.crystal?
      members = StaticArray(Int32, 8).new(0)
      count = 1
      members[0] = code_point
      Unicode.each_fold_partner(code_point) do |partner|
        next if restricted && (partner < 0x80) != (code_point < 0x80)
        raise SyntaxError.new("internal error: a case folding orbit longer than 8", Core::Position.new(literal.offset.to_i64)) if count == members.size
        members[count] = partner
        count += 1
      end
      return nil if count == 1
      offset = literal.offset
      meter.enforce { Core::Position.new(offset.to_i64) } if meter.charge(count)
      sorted = members.to_slice[0, count].sort!
      range_count = 1
      (1...count).each { |index| range_count += 1 if sorted[index] > sorted[index - 1] + 1 }
      if range_count > limits.max_class_ranges
        raise CompileLimitError.new("max_class_ranges", limits.max_class_ranges.to_i64,
          "A class of #{range_count} ranges", Core::Position.new(offset.to_i64))
      end
      ledger.charge_object(instance_sizeof(CodePointSet), "a folded literal", offset)
      ledger.charge_array(range_count * 2, sizeof(Int32), "a folded literal", offset)
      bounds = Array(Int32).new(range_count * 2)
      sorted.each do |member|
        if bounds.size > 0 && member == bounds[-1] + 1
          bounds[-1] = member
        else
          bounds << member << member
        end
      end
      CodePointSet.from_bounds(bounds)
    end

    # Returns the union of *list_of_sets*, charged to *ledger* and *meter*
    # as a class lowering at *offset* would be. The caller keeps the total
    # of their ranges within *limits*' `max_class_ranges`, so the union
    # never passes it.
    def self.union_of(list_of_sets : Array(CodePointSet), limits : CompileLimits, ledger : AllocationLedger,
                      meter : Core::WorkMeter, offset : Int32) : CodePointSet
      ledger.charge_object(instance_sizeof(Context), "a class union", offset)
      context = Context.new(offset, limits, ledger, meter)
      context.charge_array(list_of_sets.size, sizeof(RangeStream))
      list_of_streams = list_of_sets.map do |set|
        context.charge_stream
        RangeStream.new(set.list_of_bounds, false)
      end
      union(list_of_streams, context)
    end

    # Returns `.` (*matches_newline* false: everything but LF) or `\N`.
    def self.any_character(matches_newline : Bool) : CodePointSet
      return CodePointSet.from_bounds([0, CodePointSet::MAX_CODE_POINT]) if matches_newline
      CodePointSet.from_bounds([0, 0x09, 0x0B, CodePointSet::MAX_CODE_POINT])
    end

    # Sorts *list_of_ranges* in place and merges overlapping and adjacent
    # ranges into bounds.
    private def self.merge_ranges(list_of_ranges : Array({Int32, Int32}), context : Context) : Array(Int32)
      context.charge_work(list_of_ranges.size * 2)
      list_of_ranges.unstable_sort!
      context.charge_array(0, sizeof(Int32))
      bounds = [] of Int32
      list_of_ranges.each do |first, last|
        if bounds.size > 0 && first <= bounds[-1] + 1
          bounds[-1] = last if last > bounds[-1]
        else
          context.charge_range
          bounds << first << last
        end
      end
      bounds
    end

    # The fold partners of every member of the ranges in *bounds*, as
    # merged single-point bounds (they may overlap *bounds*).
    private def self.fold_partners(bounds : Array(Int32), restricted : Bool, context : Context) : Array(Int32)
      context.charge_array(0, sizeof(Int32))
      list_of_points = [] of Int32
      (bounds.size // 2).times do |index|
        visited = Unicode.each_folding_code_point(bounds[index * 2], bounds[index * 2 + 1]) do |code_point|
          Unicode.each_fold_partner(code_point) do |partner|
            next if restricted && (partner < 0x80) != (code_point < 0x80)
            context.charge_append(sizeof(Int32))
            list_of_points << partner
          end
        end
        context.charge_work(visited + 1)
      end
      context.charge_work(list_of_points.size)
      list_of_points.unstable_sort!
      context.charge_array(0, sizeof(Int32))
      partner_bounds = [] of Int32
      list_of_points.each do |code_point|
        if partner_bounds.size > 0 && code_point <= partner_bounds[-1] + 1
          partner_bounds[-1] = code_point if code_point > partner_bounds[-1]
        else
          context.charge_range
          partner_bounds << code_point << code_point
        end
      end
      partner_bounds
    end

    # Merges sorted range streams into one set with a binary heap keyed on
    # each stream's current range start: O(R log k) for R ranges from k
    # streams, charged as 1 + the heap's depth per range.
    private def self.union(list_of_streams : Array(RangeStream), context : Context) : CodePointSet
      context.charge_array(list_of_streams.size, sizeof(Int32))
      heap = Array(Int32).new(list_of_streams.size)
      list_of_streams.each_with_index do |stream, index|
        next if stream.done?
        heap << index
        sift_up(heap, list_of_streams, heap.size - 1)
      end
      context.charge_work(list_of_streams.size * (heap.size.bit_length + 1))
      context.charge_array(0, sizeof(Int32))
      bounds = [] of Int32
      until heap.empty?
        stream = list_of_streams[heap[0]]
        first = stream.current_first
        last = stream.current_last
        context.charge_work(1 + heap.size.bit_length)
        if bounds.size > 0 && first <= bounds[-1] + 1
          bounds[-1] = last if last > bounds[-1]
        else
          context.check_growth(bounds.size // 2 + 1)
          context.charge_range
          bounds << first << last
        end
        stream.advance
        if stream.done?
          heap[0] = heap[-1]
          heap.pop
        end
        sift_down(heap, list_of_streams, 0) unless heap.empty?
      end
      context.charge_set
      CodePointSet.from_bounds(bounds)
    end

    private def self.sift_up(heap : Array(Int32), list_of_streams : Array(RangeStream), position : Int32) : Nil
      index = position
      while index > 0
        parent = (index - 1) // 2
        break unless list_of_streams[heap[index]].current_first < list_of_streams[heap[parent]].current_first
        heap.swap(index, parent)
        index = parent
      end
    end

    private def self.sift_down(heap : Array(Int32), list_of_streams : Array(RangeStream), position : Int32) : Nil
      index = position
      loop do
        left = index * 2 + 1
        break if left >= heap.size
        smallest = left
        right = left + 1
        if right < heap.size && list_of_streams[heap[right]].current_first < list_of_streams[heap[left]].current_first
          smallest = right
        end
        break unless list_of_streams[heap[smallest]].current_first < list_of_streams[heap[index]].current_first
        heap.swap(index, smallest)
        index = smallest
      end
    end

    private def self.complement(set : CodePointSet, context : Context) : CodePointSet
      context.charge_array(0, sizeof(Int32))
      bounds = [] of Int32
      next_first = 0
      set.each_range do |first, last|
        if first > next_first
          context.check_growth(bounds.size // 2 + 1)
          context.charge_range
          bounds << next_first << first - 1
        end
        next_first = last + 1
      end
      if next_first <= CodePointSet::MAX_CODE_POINT
        context.check_growth(bounds.size // 2 + 1)
        context.charge_range
        bounds << next_first << CodePointSet::MAX_CODE_POINT
      end
      context.charge_work(set.range_count + 1)
      context.charge_set
      CodePointSet.from_bounds(bounds)
    end

    # The limits, ledger and meter of one class lowering.
    private class Context
      def initialize(@offset : Int32, @limits : CompileLimits, @ledger : AllocationLedger, @meter : Core::WorkMeter)
      end

      def charge_work(count : Int32) : Nil
        offset = @offset
        @meter.enforce { Core::Position.new(offset.to_i64) } if @meter.charge(count)
      end

      # An array created with *capacity* elements of *element_bytes*.
      def charge_array(capacity : Int32, element_bytes : Int32) : Nil
        @ledger.charge_array(capacity, element_bytes, "a class lowering list", @offset)
      end

      # One element of *element_bytes* appended to a growing array.
      def charge_append(element_bytes : Int32) : Nil
        @ledger.charge_append(element_bytes, "a class member", @offset)
      end

      # One range (two bounds) appended to a growing bounds array.
      def charge_range : Nil
        @ledger.charge_append(2 * sizeof(Int32), "a class range", @offset)
      end

      # A range stream object and its entry in the stream list.
      def charge_stream : Nil
        @ledger.charge_object(instance_sizeof(RangeStream), "a class member", @offset)
        @ledger.charge_append(sizeof(RangeStream), "a class member", @offset)
      end

      # A `CodePointSet` object (its bounds are charged as they grow).
      def charge_set : Nil
        @ledger.charge_object(instance_sizeof(CodePointSet), "a class", @offset)
      end

      # An empty `Set` with its first block of entries.
      def charge_hash : Nil
        @ledger.charge_object(instance_sizeof(Hash(Ast::ClassItem, Nil)), "a class member set", @offset)
        @ledger.charge_array(8, sizeof(Ast::ClassItem) + 8, "a class member set", @offset)
      end

      # One member added to the set of distinct members.
      def charge_hash_entry(key_bytes : Int32) : Nil
        @ledger.charge_hash_entry(key_bytes, "a class member set", @offset)
      end

      # Refuses a union that would have more ranges than the limit allows;
      # negation changes the count by at most one, so one spare range is
      # allowed until `check_final`.
      def check_growth(count : Int32) : Nil
        refuse(count) if count.to_i64 > @limits.max_class_ranges.to_i64 + 1
      end

      def check_final(count : Int32) : Nil
        refuse(count) if count > @limits.max_class_ranges
      end

      private def refuse(count : Int32) : NoReturn
        raise CompileLimitError.new("max_class_ranges", @limits.max_class_ranges.to_i64,
          "A class of #{count} ranges", Core::Position.new(@offset.to_i64))
      end
    end

    # A sorted range source for the union: a Unicode table set or an array
    # of bounds, read directly or as its complement. It only reads the
    # bounds it is given.
    private class RangeStream
      # The bounds as `first, last` pairs (an ASCII set's array, or the
      # decoded table of a Unicode set).
      @bounds : Slice(Int32)
      @count : Int32
      @index : Int32
      getter current_first : Int32 = 0
      getter current_last : Int32 = 0
      getter? done : Bool = false

      def self.for_item(item : Ast::ClassItem, ascii_set_bounds : Array(Array(Int32))) : self
        if item.item_kind.unicode_set?
          new(item.first, item.negated)
        else
          new(ascii_set_bounds[item.first], item.negated)
        end
      end

      def initialize(bounds : Array(Int32), @negated : Bool)
        @bounds = Slice.new(bounds.to_unsafe, bounds.size, read_only: true)
        @count = bounds.size // 2
        @index = 0
        load
      end

      def initialize(set_id : Int32, @negated : Bool)
        @bounds = Unicode.decoded_ranges(set_id)
        @count = Unicode.range_count(set_id)
        @index = 0
        load
      end

      def advance : Nil
        @index += 1
        load
      end

      # Loads the range at @index (a gap between ranges when negated),
      # skipping empty gaps.
      private def load : Nil
        unless @negated
          if @index >= @count
            @done = true
            return
          end
          @current_first, @current_last = range_at(@index)
          return
        end
        while @index <= @count
          first = @index == 0 ? 0 : range_at(@index - 1)[1] + 1
          last = @index == @count ? CodePointSet::MAX_CODE_POINT : range_at(@index)[0] - 1
          if first <= last
            @current_first = first
            @current_last = last
            return
          end
          @index += 1
        end
        @done = true
      end

      private def range_at(index : Int32) : {Int32, Int32}
        {@bounds[index * 2], @bounds[index * 2 + 1]}
      end
    end
  end
end
