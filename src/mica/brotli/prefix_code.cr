module Mica::Brotli
  # Builds two-level lookup tables for canonical prefix codes (RFC 7932,
  # section 3.2) into a shared `Store`.
  #
  # An entry is a `UInt32`: the symbol in the upper 24 bits and a bit
  # count in the lower 8. The root level is indexed by the next
  # `ROOT_BITS` bits of input (least significant bit first, as Brotli
  # packs codes). A root entry whose count is above `ROOT_BITS` points to
  # a second-level table: its symbol field is that table's offset from the
  # root's start and its count is `ROOT_BITS` plus the second level's
  # index width. Second-level entries hold the code length minus
  # `ROOT_BITS`.
  #
  # :nodoc:
  module PrefixCode
    ROOT_BITS = 8
    ROOT_SIZE = 1 << ROOT_BITS
    # The longest code length Brotli allows.
    MAX_LENGTH = 15

    # The tables of one metablock header, end to end.
    class Store
      getter size : Int32 = 0

      def initialize
        @entries = Slice(UInt32).new(4_096)
      end

      def to_unsafe : Pointer(UInt32)
        @entries.to_unsafe
      end

      def clear : Nil
        @size = 0
      end

      # Drops every entry from *size* on.
      def truncate(size : Int32) : Nil
        @size = size
      end

      # Adds *count* entries at the end and returns where they start.
      def append(count : Int32) : Int32
        start = @size
        needed = start + count
        if needed > @entries.size
          capacity = @entries.size
          while capacity < needed
            capacity <<= 1
          end
          grown = Slice(UInt32).new(capacity)
          grown.copy_from(@entries.to_unsafe, start)
          @entries = grown
        end
        @size = needed
        start
      end
    end

    # Per-length symbol lists (google/brotli's `symbol_lists`), filled as
    # code lengths are read so the builder needs no sorting pass. Node
    # `length` (0 to 15) heads the list of that length; symbol *s* is node
    # `s + HEADS`. Each node holds the next node of its list.
    HEADS = 16

    # The node that *symbol* occupies in a symbol list.
    @[AlwaysInline]
    def self.node(symbol : Int32) : UInt16
      (symbol &+ HEADS).to_u16!
    end

    # Appends the table for the code with *lengths* (one entry per symbol
    # of the alphabet, 0 for an unused symbol) to *store* and returns where
    # it starts. *lists* needs `lengths.size + HEADS` entries. See
    # `build_from_lists`.
    def self.build(lengths : Slice(UInt8), store : Store, lists : Slice(UInt16)) : Int32
      count = StaticArray(Int32, 16).new(0)
      tail = StaticArray(UInt16, 16).new { |length| length.to_u16 }
      used = 0
      lengths.each_with_index do |length, symbol|
        next if length == 0
        count[length] += 1
        lists[tail[length]] = node(symbol)
        tail[length] = node(symbol)
        used += 1
      end
      build_from_lists(lists, used, count, store)
    end

    # Appends the table for a code to *store* and returns where it starts.
    # *lists* holds, for each code length, its *count* symbols in
    # increasing order (see `HEADS`); *used* is the number of symbols with
    # a nonzero length. The code must be complete (the caller has checked
    # the Kraft sum), or have exactly one used symbol, which then decodes
    # from zero bits.
    def self.build_from_lists(lists : Slice(UInt16), used : Int32,
                              count : StaticArray(Int32, 16), store : Store) : Int32
      start = store.append(ROOT_SIZE)
      if used <= 1
        entry = 0_u32
        if used == 1
          length = (1..MAX_LENGTH).find { |width| count[width] != 0 } || 0
          entry = (lists[length].to_u32 &- HEADS) << 8
        end
        Slice.new(store.to_unsafe + start, ROOT_SIZE).fill(entry)
        return start
      end

      nodes = lists.to_unsafe
      code = 0
      max_length = MAX_LENGTH
      while max_length > 1 && count[max_length] == 0
        max_length -= 1
      end
      # Codes of at most ROOT_BITS bits fill the root directly. A code no
      # longer than *table_bits* fills only the first `1 << table_bits`
      # entries, which then repeat to fill the root (as google/brotli's
      # builder does): copying is cheaper than striding over 256 entries.
      table_bits = max_length < ROOT_BITS ? max_length : ROOT_BITS
      table_size = 1 << table_bits
      table = store.to_unsafe + start
      (1..ROOT_BITS).each do |length|
        step = 1 << length
        at = length
        count[length].times do
          at = nodes[at].to_i32
          entry = ((at &- HEADS).to_u32! << 8) | length.to_u32
          index = reverse(code, length)
          while index < table_size
            table[index] = entry
            index += step
          end
          code += 1
        end
        code <<= 1
      end
      filled = table_size
      while filled < ROOT_SIZE
        (table + filled).copy_from(table, filled)
        filled <<= 1
      end

      # Longer codes go to second-level tables, one per root index; codes
      # sharing their first ROOT_BITS bits are contiguous in canonical
      # order.
      low = -1
      sub_start = 0
      sub_size = 0
      (ROOT_BITS + 1..MAX_LENGTH).each do |length|
        step = 1 << (length - ROOT_BITS)
        at = length
        while count[length] > 0
          at = nodes[at].to_i32
          reversed = reverse(code, length)
          root = reversed & (ROOT_SIZE - 1)
          if root != low
            width = next_table_bits(count, length)
            sub_size = 1 << width
            sub_start = store.append(sub_size)
            low = root
            (store.to_unsafe + start)[root] = ((sub_start - start).to_u32 << 8) | (ROOT_BITS + width).to_u32
          end
          entry = ((at &- HEADS).to_u32! << 8) | (length - ROOT_BITS).to_u32
          index = reversed >> ROOT_BITS
          table = store.to_unsafe + sub_start
          while index < sub_size
            table[index] = entry
            index += step
          end
          code += 1
          count[length] -= 1
        end
        code <<= 1
      end
      start
    end

    # The index width of the second-level table that starts with a code of
    # *length* bits, from the codes still to place (zlib's method).
    private def self.next_table_bits(count : StaticArray(Int32, 16), length : Int32) : Int32
      left = 1 << (length - ROOT_BITS)
      while length < MAX_LENGTH
        left -= count[length]
        break if left <= 0
        length += 1
        left <<= 1
      end
      length - ROOT_BITS
    end

    {% if flag?(:x86_64) %}
      # Each byte with its bits reversed. x86-64 has no bit-reverse
      # instruction (`bit_reverse` expands to about 20 instructions), so
      # `reverse` looks bytes up here instead.
      REVERSED_BYTE = {% begin %}
        StaticArray[
          {% for byte in 0...256 %}
            {% reversed = 0 %}
            {% for bit in 0...8 %}
              {% if (byte // (1 << bit)) % 2 == 1 %}{% reversed = reversed + (1 << (7 - bit)) %}{% end %}
            {% end %}
            {{ reversed }}_u8,
          {% end %}
        ]
      {% end %}

      # Reverses the low *width* (1 to 15) bits of *code*, which is below
      # `1 << width`.
      @[AlwaysInline]
      def self.reverse(code : Int32, width : Int32) : Int32
        low = REVERSED_BYTE.unsafe_fetch(code & 0xFF).to_i32!
        return low.unsafe_shr(8 &- width) if width <= 8
        ((low << 8) | REVERSED_BYTE.unsafe_fetch((code >> 8) & 0xFF).to_i32!).unsafe_shr(16 &- width)
      end
    {% else %}
      # Reverses the low *width* (1 to 15) bits of *code*, which is below
      # `1 << width`.
      @[AlwaysInline]
      def self.reverse(code : Int32, width : Int32) : Int32
        (code.to_u32.bit_reverse >> (32 - width)).to_i32
      end
    {% end %}
  end
end
