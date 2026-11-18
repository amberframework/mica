module Mica::Regex
  # Lowers syntax-tree classes to `CodePointSet`s, with case folding chosen
  # per dialect:
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
  # streams), and the result is refused with `CompileLimitError` naming
  # `max_class_ranges` as soon as it would grow past the limit; every array
  # is charged to the `AllocationLedger` before it grows.
  module ClassLowering
    # Bytes charged per range appended (two bounds, with room for geometric
    # growth).
    RANGE_BYTES = 16

    # Lowers *char_class* for *dialect*.
    def self.lower(char_class : Ast::CharClass, dialect : Dialect, limits : CompileLimits, ledger : AllocationLedger,
                   meter : Core::WorkMeter) : CodePointSet
      context = Context.new(char_class.offset, limits, ledger, meter)
      options = char_class.options
      folding = options.ignore_case? && !dialect.xsd?
      restricted = options.caseless_restrict? && dialect.crystal?
      list_of_ranges = [] of {Int32, Int32}
      list_of_streams = [] of RangeStream
      char_class.list_of_items.each do |item|
        context.charge_work(1)
        if item.item_kind.range?
          context.charge_list_entry
          list_of_ranges << {item.first, item.last}
        else
          context.charge_stream
          list_of_streams << RangeStream.for_item(item)
        end
      end
      unless list_of_ranges.empty?
        context.charge_work(list_of_ranges.size * 2)
        literal_set = CodePointSet.new(list_of_ranges)
        context.charge_stream
        list_of_streams << RangeStream.new(literal_set.list_of_bounds, false)
        if folding && dialect.crystal?
          partners = fold_partners(literal_set, restricted, context)
          context.charge_stream
          list_of_streams << RangeStream.new(partners, false)
        end
      end
      set = union(list_of_streams, context)
      if folding && dialect.ecma262?
        partners = fold_partners(set, false, context)
        set = union([RangeStream.new(set.list_of_bounds, false), RangeStream.new(partners, false)], context)
      end
      set = complement(set, context) if char_class.negated?
      context.check_final(set.range_count)
      set
    end

    # Returns the set a literal stands for: the code point, closed over its
    # simple case folding orbit under `IgnoreCase` (and kept within ASCII or
    # non-ASCII under `CaselessRestrict` in the Crystal dialect).
    def self.literal(code_point : Int32, options : CompileOptions, dialect : Dialect) : Array(Int32)
      members = [code_point]
      return members unless options.ignore_case? && !dialect.xsd?
      restricted = options.caseless_restrict? && dialect.crystal?
      Unicode.each_fold_partner(code_point) do |partner|
        members << partner unless restricted && (partner < 0x80) != (code_point < 0x80)
      end
      members.sort!
    end

    # Returns `.` (*matches_newline* false: everything but LF) or `\N`.
    def self.any_character(matches_newline : Bool) : CodePointSet
      return CodePointSet.from_bounds([0, CodePointSet::MAX_CODE_POINT]) if matches_newline
      CodePointSet.from_bounds([0, 0x09, 0x0B, CodePointSet::MAX_CODE_POINT])
    end

    # The fold partners of every member of *set*, as merged single-point
    # bounds (they may overlap *set*).
    private def self.fold_partners(set : CodePointSet, restricted : Bool, context : Context) : Array(Int32)
      list_of_points = [] of Int32
      set.each_range do |first, last|
        visited = Unicode.each_folding_code_point(first, last) do |code_point|
          Unicode.each_fold_partner(code_point) do |partner|
            next if restricted && (partner < 0x80) != (code_point < 0x80)
            context.charge_point
            list_of_points << partner
          end
        end
        context.charge_work(visited + 1)
      end
      context.charge_work(list_of_points.size)
      list_of_points.sort!
      bounds = [] of Int32
      list_of_points.each do |code_point|
        if bounds.size > 0 && code_point <= bounds[-1] + 1
          bounds[-1] = code_point if code_point > bounds[-1]
        else
          context.charge_point
          bounds << code_point << code_point
        end
      end
      bounds
    end

    # Merges sorted range streams into one set with a binary heap keyed on
    # each stream's current range start: O(R log k) for R ranges from k
    # streams.
    private def self.union(list_of_streams : Array(RangeStream), context : Context) : CodePointSet
      heap = [] of Int32
      list_of_streams.each_with_index do |stream, index|
        next if stream.done?
        heap << index
        sift_up(heap, list_of_streams, heap.size - 1)
      end
      bounds = [] of Int32
      until heap.empty?
        stream = list_of_streams[heap[0]]
        first = stream.current_first
        last = stream.current_last
        context.charge_work(1)
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

      def charge_range : Nil
        @ledger.charge(RANGE_BYTES, "a class range", @offset)
      end

      def charge_point : Nil
        @ledger.charge(8, "a case folding partner", @offset)
      end

      def charge_list_entry : Nil
        @ledger.charge(16, "a class range", @offset)
      end

      def charge_stream : Nil
        @ledger.charge(instance_sizeof(RangeStream) + 8, "a class member", @offset)
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

    # A sorted range source for the union: a Unicode table set, an ASCII
    # set or an array of bounds, read directly or as its complement.
    private class RangeStream
      @bounds : Array(Int32)?
      @set_id : Int32
      @count : Int32
      @index : Int32
      getter current_first : Int32 = 0
      getter current_last : Int32 = 0
      getter? done : Bool = false

      def self.for_item(item : Ast::ClassItem) : self
        if item.item_kind.unicode_set?
          new(item.first, item.negated)
        else
          bounds = [] of Int32
          Ast::AsciiSet.new(item.first).ranges.each { |first, last| bounds << first << last }
          new(bounds, item.negated)
        end
      end

      def initialize(bounds : Array(Int32), @negated : Bool)
        @bounds = bounds
        @set_id = -1
        @count = bounds.size // 2
        @index = 0
        load
      end

      def initialize(@set_id : Int32, @negated : Bool)
        @bounds = nil
        @count = Unicode.range_count(@set_id)
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
        if bounds = @bounds
          {bounds[index * 2], bounds[index * 2 + 1]}
        else
          Unicode.range_at(@set_id, index)
        end
      end
    end
  end
end
