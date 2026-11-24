module Mica::HPACK
  # The dynamic table of one side of one connection (RFC 7541, section
  # 2.3.2): newest entry first, sized by `Header#size`, evicting the oldest
  # entries to stay within `capacity`.
  #
  # The table also keeps an insertion count, so an encoder can find an
  # entry's current index from the count it had when it was added.
  class DynamicTable
    # The most bytes the entries may take (the current maximum size).
    getter capacity : Int32
    # The bytes the entries take now.
    getter size : Int32 = 0
    # How many entries were ever added.
    getter insertions : Int64 = 0_i64

    @entries = Deque(Header).new

    def initialize(@capacity : Int32)
    end

    # Returns the number of entries.
    def length : Int32
      @entries.size
    end

    # Returns the entry at the 0-based *offset* from the newest, or nil.
    def []?(offset : Int32) : Header?
      @entries[offset]?
    end

    # Adds *header* as the newest entry, evicting old entries first. A
    # header larger than the capacity empties the table and is not added.
    # Yields each evicted entry with its insertion number.
    def add(header : Header, & : Header, Int64 ->) : Nil
      size = header.size
      evict_to(@capacity - size) { |evicted, insertion| yield evicted, insertion }
      @insertions += 1
      return if size > @capacity
      @entries.unshift(header)
      @size += size
    end

    # Adds *header*, as `add` with a block.
    def add(header : Header) : Nil
      add(header) { }
    end

    # Changes the capacity, evicting entries that no longer fit. Yields
    # each evicted entry with its insertion number.
    def resize(capacity : Int32, & : Header, Int64 ->) : Nil
      @capacity = capacity
      evict_to(capacity) { |evicted, insertion| yield evicted, insertion }
    end

    # Changes the capacity, evicting entries that no longer fit.
    def capacity=(capacity : Int32) : Nil
      resize(capacity) { }
    end

    private def evict_to(target : Int32, & : Header, Int64 ->) : Nil
      while @size > target && !@entries.empty?
        evicted = @entries.pop
        @size -= evicted.size
        yield evicted, @insertions - @entries.size
      end
    end
  end
end
