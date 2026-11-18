module Mica::Regex
  # A set of Unicode scalar values and surrogate code points, held as
  # sorted, disjoint, non-adjacent ranges. Classes lower to these sets.
  #
  # ```
  # set = Mica::Regex::CodePointSet.new([{0x61, 0x7A}, {0x30, 0x39}])
  # set.to_s # => "[0-9a-z]"
  # ```
  class CodePointSet
    # The highest code point.
    MAX_CODE_POINT = 0x10FFFF

    # Range bounds, two entries per range: first, last.
    getter list_of_bounds : Array(Int32)

    # Builds a set from *ranges* in any order; overlapping and adjacent
    # ranges are merged.
    def self.new(ranges : Array({Int32, Int32})) : self
      sorted = ranges.sort
      bounds = [] of Int32
      sorted.each do |first, last|
        if bounds.size > 0 && first <= bounds[-1] + 1
          bounds[-1] = last if last > bounds[-1]
        else
          bounds << first << last
        end
      end
      from_bounds(bounds)
    end

    # Wraps *bounds* (already sorted, disjoint and non-adjacent) without
    # copying.
    def self.from_bounds(bounds : Array(Int32)) : self
      new(bounds)
    end

    # Wraps *list_of_bounds*; see `from_bounds`.
    def initialize(@list_of_bounds : Array(Int32))
    end

    # Returns the number of ranges.
    def range_count : Int32
      @list_of_bounds.size // 2
    end

    # Returns true when the set has no members.
    def empty? : Bool
      @list_of_bounds.empty?
    end

    # Returns true when the set holds every code point.
    def full? : Bool
      @list_of_bounds.size == 2 && @list_of_bounds[0] == 0 && @list_of_bounds[1] == MAX_CODE_POINT
    end

    # Returns true when *code_point* is a member (a binary search).
    def includes?(code_point : Int32) : Bool
      low = 0
      high = range_count
      while low < high
        middle = (low + high) // 2
        if @list_of_bounds[middle * 2 + 1] < code_point
          low = middle + 1
        elsif @list_of_bounds[middle * 2] > code_point
          high = middle
        else
          return true
        end
      end
      false
    end

    # Yields each range as first and last code point, in order.
    def each_range(& : Int32, Int32 ->) : Nil
      range_count.times do |index|
        yield @list_of_bounds[index * 2], @list_of_bounds[index * 2 + 1]
      end
    end

    # Returns the number of code points in the set.
    def size : Int64
      total = 0_i64
      each_range { |first, last| total += last - first + 1 }
      total
    end

    def ==(other : CodePointSet) : Bool
      @list_of_bounds == other.list_of_bounds
    end

    # Writes the set as a bracketed class, for diagnostics and specs.
    def to_s(io : IO) : Nil
      io << '['
      each_range do |first, last|
        write_code_point(io, first)
        next if first == last
        io << '-' if last > first + 1
        write_code_point(io, last)
      end
      io << ']'
    end

    private def write_code_point(io : IO, code_point : Int32) : Nil
      if (0x30 <= code_point <= 0x39) || (0x41 <= code_point <= 0x5A) || (0x61 <= code_point <= 0x7A)
        io << code_point.chr
      else
        io << "\\x{" << code_point.to_s(16).upcase << '}'
      end
    end
  end
end
