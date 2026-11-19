module Mica::Regex
  # A literal accelerator (roadmap 6.2.2): finds the next position at or
  # after a given one where one of a `LiteralSet`'s literals occurs, so the
  # lazy DFA can skip the bytes in between while it sits in its start
  # state. Three searchers, chosen when the expression is first searched:
  #
  # - **first bytes** (memchr style): the literals start with at most three
  #   distinct bytes; each is found with `memchr`, which libc vectorizes;
  # - **rare byte**: one literal; its least common byte (by a fixed
  #   frequency rank) is found with `memchr` and the literal is checked
  #   around it. When even that byte is common in text (`COMMON_RANK`),
  #   the searcher looks for a pair instead, the two least common bytes
  #   at their distance in the literal, eight positions per step;
  # - **packed** (Teddy style): up to 64 literals; three 256-entry masks,
  #   one per leading byte position, say which literals can have that byte
  #   there, and a position is a candidate when the three masks share a bit.
  #
  # Every candidate is verified against the literals before it is returned,
  # so a returned position is where a literal really starts.
  #
  # **Progress.** A `PrefilterScan` belongs to one search call and only moves
  # forward: it remembers where each byte was last found, so a `memchr` never
  # rescans bytes, and every byte it reads, and every literal byte it
  # compares, is charged to the call's `SearchMeter`. Total work is O(n·k·l)
  # for k literals of at most l bytes (both bounded by `LiteralSet`).
  class Prefilter
    enum Kind
      FirstBytes
      RareByte
      Packed
    end

    getter kind : Kind
    getter literal_set : LiteralSet
    # The distinct first bytes (`FirstBytes`), or the rare byte or pair
    # (`RareByte`).
    getter list_of_needles : Array(UInt8)
    # For `RareByte`, where the rare byte (or the first of the pair) sits
    # in the literal.
    getter needle_offset : Int32
    # For `RareByte` with a pair, how far the second byte of the pair sits
    # after the first (0 without a pair).
    getter pair_gap : Int32
    # For `Packed`, how many leading bytes the masks cover (1 to 3).
    getter mask_width : Int32
    @masks : Slice(UInt64)
    @literals : Array(Bytes)
    # For each byte, the literals that start with it (bit per literal).
    @starting_with : StaticArray(UInt64, 256)

    def initialize(@literal_set : LiteralSet)
      @literals = @literal_set.list_of_literals
      @starting_with = StaticArray(UInt64, 256).new(0_u64)
      @literals.each_with_index { |literal, index| @starting_with[literal[0]] |= 1_u64 << index }
      @needle_offset = 0
      @pair_gap = 0
      @mask_width = 0
      @masks = Slice(UInt64).empty
      first_bytes = @literals.map(&.[0]).uniq!
      if @literals.size == 1
        @kind = Kind::RareByte
        literal = @literals[0]
        @needle_offset = (0...literal.size).min_by { |index| Prefilter.rank(literal[index]) }
        @list_of_needles = [literal[@needle_offset]]
        if literal.size > 1 && Prefilter.rank(literal[@needle_offset]) >= COMMON_RANK
          # The second byte is the least common of the other offsets, a
          # different byte value first (a pair of two values is rarer).
          rare = literal[@needle_offset]
          other = (0...literal.size).reject(@needle_offset).min_by { |index| {literal[index] == rare ? 1 : 0, Prefilter.rank(literal[index])} }
          first, second = {@needle_offset, other}.minmax
          @needle_offset = first
          @pair_gap = second - first
          @list_of_needles = [literal[first], literal[second]]
        end
      elsif first_bytes.size <= 3
        @kind = Kind::FirstBytes
        @list_of_needles = first_bytes
      else
        @kind = Kind::Packed
        @list_of_needles = [] of UInt8
        @mask_width = Math.min(3, @literal_set.minimum_length)
        @masks = Slice(UInt64).new(256 * @mask_width, 0_u64)
        @literals.each_with_index do |literal, index|
          bit = 1_u64 << index
          @mask_width.times { |column| @masks[column * 256 + literal[column]] |= bit }
        end
      end
    end

    # Returns the index of the highest-priority literal that occurs at
    # *at*, or -1, trying only the literals whose first byte is the byte at
    # *at* (and, for `Packed`, only those in *candidates*). Charges the
    # bytes compared.
    def literal_at(haystack : Bytes, at : Int32, meter : SearchMeter, candidates : UInt64 = UInt64::MAX) : Int32
      return -1 if at >= haystack.size
      bits = candidates & @starting_with.unsafe_fetch(haystack.unsafe_fetch(at))
      while bits != 0
        index = bits.trailing_zeros_count.to_i32
        bits &= bits - 1
        literal = @literals.unsafe_fetch(index)
        meter.charge(literal.size, at)
        return index if Prefilter.literal_fits_at?(haystack, at, literal)
      end
      -1
    end

    # The longest literal `literal_fits_at?` compares with a byte loop.
    SHORT_LITERAL = 8

    # True when *literal* occurs in *haystack* at *at*. Up to
    # `SHORT_LITERAL` bytes a byte loop beats a `memcmp` call; the first
    # byte is already known to match, and a one-byte literal needs no
    # compare.
    @[AlwaysInline]
    protected def self.literal_fits_at?(haystack : Bytes, at : Int32, literal : Bytes) : Bool
      size = literal.size
      return false if at + size > haystack.size
      if size > SHORT_LITERAL
        return LibC.memcmp(haystack.to_unsafe + at + 1, literal.to_unsafe + 1, size - 1) == 0
      end
      index = 1
      while index < size
        return false unless haystack.unsafe_fetch(at + index) == literal.unsafe_fetch(index)
        index += 1
      end
      true
    end

    # :nodoc:
    # The `Packed` masks: 256 entries per covered leading byte position.
    def masks : Slice(UInt64)
      @masks
    end

    # Returns the length of literal *index*.
    def literal_size(index : Int32) : Int32
      @literals[index].size
    end

    # A frequency rank for *byte* in typical text (higher is more common),
    # for choosing the rare byte. Letters and spaces rank high, control
    # bytes and non-ASCII lead bytes low.
    def self.rank(byte : UInt8) : Int32
      return 160 if byte >= 0xC0 # a lead byte: one per non-ASCII character
      return 96 if byte >= 0x80  # a continuation byte: spread over many values
      COMMON_BYTES.index(byte.unsafe_chr).try { |index| 255 - index } || 64
    end

    # The rank from which a rare byte is too common for `memchr` to skip
    # far: the space and the eleven most common letters, each found every
    # few dozen bytes of text.
    COMMON_RANK = 243

    # Bytes in descending order of how often they occur in English text and
    # source code.
    COMMON_BYTES = " etaoinsrhldcumfpgwybvkxjqzETAOINSRHLDCUMFPGWYBVKXJQZ0123456789\n.,;:-_'\"()/=<>{}[]*#\t"
  end

  # :nodoc:
  # The forward-only state of a prefilter over one haystack, owned by one
  # search call (see `Prefilter`, "Progress").
  #
  # **The guard.** Every candidate verified counts, matching or not. Once
  # `GUARD_CANDIDATES` have been verified and they came closer together
  # than `MINIMUM_SKIP` bytes on average, the scan is `ineffective?`: a
  # scan that is only an accelerator (not the literal search itself) then
  # stops at the candidate it holds and returns it unverified, which is
  # safe (no match starts before it), and the caller stops using it.
  class PrefilterScan
    GUARD_CANDIDATES = 32
    MINIMUM_SKIP     =  8
    # The bytes a scan reads between two charges to the meter.
    CHARGE_CHUNK = 4096
    # A byte in every lane of a word, and the high bit of every lane (the
    # pair search).
    LANE_ONES  = 0x0101010101010101_u64
    LANE_HIGHS = 0x8080808080808080_u64

    getter prefilter : Prefilter
    # How many candidates the scan has verified.
    getter candidates = 0
    # How many bytes the scan has moved past in all.
    getter skipped = 0_i64
    @guard_from = 0
    # The positions where each needle was last found (-1: not yet looked;
    # Int32::MAX: absent from there on).
    @found_at : StaticArray(Int32, 3)
    @scanned_from : StaticArray(Int32, 3)
    @packed_from = 0

    # With *verified_only* (the literal search), the scan never stops early:
    # every position it returns starts a literal.
    def initialize(@prefilter : Prefilter, @haystack : Bytes, @verified_only : Bool = false)
      @found_at = StaticArray(Int32, 3).new(-1)
      @scanned_from = StaticArray(Int32, 3).new(0)
    end

    # Starts the scan over on *haystack*, as a new scan would (a searcher
    # reuses its scan from one call to the next). With *keep_positions*
    # (the haystack is the one the last call scanned), where each needle
    # was found stays known.
    def reset(@haystack : Bytes, *, keep_positions : Bool = false) : Nil
      @candidates = 0
      @skipped = 0_i64
      @guard_from = 0
      @packed_from = 0
      return if keep_positions
      @found_at = StaticArray(Int32, 3).new(-1)
      @scanned_from = StaticArray(Int32, 3).new(0)
    end

    # True when candidates have been too dense for the scan to pay off
    # (`GUARD_CANDIDATES`, `MINIMUM_SKIP`); the caller then stops using it
    # for the rest of the call.
    def ineffective? : Bool
      @candidates >= GUARD_CANDIDATES && @skipped < @candidates.to_i64 * MINIMUM_SKIP
    end

    # Returns the first position at or after *from* where a literal starts,
    # or -1.
    def find(from : Int32, meter : SearchMeter) : Int32
      @guard_from = from
      case @prefilter.kind
      in .first_bytes? then find_first_bytes(from, meter)
      in .rare_byte?   then find_rare_byte(from, meter)
      in .packed?      then find_packed(from, meter)
      end
    end

    # Verifies *candidate*, counting it for the guard. Returns true when a
    # literal starts there, or when the scan should stop at it (see the
    # class description).
    private def accept?(candidate : Int32, meter : SearchMeter, bits : UInt64 = UInt64::MAX) : Bool
      @candidates += 1
      @skipped += candidate - @guard_from if candidate > @guard_from
      @guard_from = candidate + 1
      return true if @prefilter.literal_at(@haystack, candidate, meter, bits) >= 0
      !@verified_only && ineffective?
    end

    private def find_first_bytes(from : Int32, meter : SearchMeter) : Int32
      at = from
      while at < @haystack.size
        candidate = Int32::MAX
        @prefilter.list_of_needles.size.times do |needle|
          candidate = Math.min(candidate, next_needle(needle, @prefilter.list_of_needles[needle], at, meter))
        end
        return -1 if candidate == Int32::MAX
        return candidate if accept?(candidate, meter)
        at = candidate + 1
      end
      -1
    end

    private def find_rare_byte(from : Int32, meter : SearchMeter) : Int32
      return find_rare_pair(from, meter) if @prefilter.pair_gap > 0
      offset = @prefilter.needle_offset
      needle = @prefilter.list_of_needles[0]
      at = from
      while at < @haystack.size
        position = next_needle(0, needle, at + offset, meter)
        return -1 if position == Int32::MAX
        candidate = position - offset
        return candidate if accept?(candidate, meter)
        at = candidate + 1
      end
      -1
    end

    # The pair search: a position is a candidate when the pair's first
    # byte sits at the needle offset after it and the second byte
    # `Prefilter#pair_gap` further on. Eight positions are tested at once,
    # one byte per lane of a 64-bit word: a lane holding the wanted byte
    # becomes zero after an XOR, and the zero-lane test can also flag a
    # lane above a real zero, so the lowest flagged lane is a candidate
    # that `accept?` verifies (a false one is skipped like any candidate
    # that fails). The meter is charged as in `find_packed`.
    private def find_rare_pair(from : Int32, meter : SearchMeter) : Int32
      offset = @prefilter.needle_offset
      gap = @prefilter.pair_gap
      first = @prefilter.list_of_needles[0]
      second = @prefilter.list_of_needles[1]
      first_lanes = LANE_ONES &* first
      second_lanes = LANE_ONES &* second
      last = @haystack.size - @prefilter.literal_size(0)
      at = Math.max(from, 0)
      bytes = @haystack.to_unsafe
      while at <= last
        stop = at + meter.readable(Math.min(CHARGE_CHUNK, last + 1 - at), at) - 1
        chunk_from = at
        found = -1
        while at + 7 <= stop
          lanes = PrefilterScan.zero_lanes(PrefilterScan.word_at(bytes + at + offset) ^ first_lanes) &
                  PrefilterScan.zero_lanes(PrefilterScan.word_at(bytes + at + offset + gap) ^ second_lanes)
          if lanes != 0
            found = at + lanes.trailing_zeros_count // 8
            break
          end
          at += 8
        end
        if found < 0
          while at <= stop
            if bytes[at + offset] == first && bytes[at + offset + gap] == second
              found = at
              break
            end
            at += 1
          end
        end
        if found >= 0
          meter.charge(found - chunk_from + 1, found)
          return found if accept?(found, meter)
          at = found + 1
        elsif at > chunk_from
          meter.charge(at - chunk_from, chunk_from)
        end
      end
      meter.charge(@haystack.size - at, at) if at < @haystack.size
      -1
    end

    # The eight bytes at *pointer* as one little-endian word (an unaligned
    # read).
    protected def self.word_at(pointer : UInt8*) : UInt64
      word = 0_u64
      pointerof(word).as(UInt8*).copy_from(pointer, 8)
      word
    end

    # The high bit of each lane of *word* that may be zero: every zero lane
    # is flagged, and a lane above a zero lane can be flagged too.
    protected def self.zero_lanes(word : UInt64) : UInt64
      (word &- LANE_ONES) & ~word & LANE_HIGHS
    end

    # Returns the first position at or after *from* holding *needle*
    # (`Int32::MAX` when none), reusing the last result while it is still
    # ahead, and charging each byte `memchr` reads once. The scan runs in
    # windows of at most `CHARGE_CHUNK` bytes that the meter allows before
    # each is read (`SearchMeter#readable`), so a search over budget stops
    # before the first byte it cannot pay for.
    private def next_needle(slot : Int32, needle : UInt8, from : Int32, meter : SearchMeter) : Int32
      found_at = @found_at.unsafe_fetch(slot)
      return found_at if from >= @scanned_from.unsafe_fetch(slot) && found_at >= from
      size = @haystack.size
      return Int32::MAX if from >= size
      index = Int32::MAX
      at = from
      bytes = @haystack.to_unsafe
      while at < size
        window = meter.readable(Math.min(CHARGE_CHUNK, size - at), at)
        found = LibC.memchr(bytes + at, needle.to_i32, window)
        unless found.null?
          offset = (found.as(UInt8*) - (bytes + at)).to_i32
          index = at + offset
          meter.charge(offset + 1, at)
          break
        end
        meter.charge(window, at)
        at += window
      end
      meter.charge(1, size) if index == Int32::MAX
      @scanned_from[slot] = from
      @found_at[slot] = index
    end

    # The packed search, charging each byte it reads once, at each
    # candidate and in windows of at most `CHARGE_CHUNK` positions that the
    # meter allows before each is read (`SearchMeter#readable`).
    private def find_packed(from : Int32, meter : SearchMeter) : Int32
      width = @prefilter.mask_width
      masks = @prefilter.masks
      last = @haystack.size - width
      at = Math.max(from, 0)
      bytes = @haystack.to_unsafe
      table = masks.to_unsafe
      while at <= last
        # A window ends at its first candidate: verifying it charges the
        # meter, so the next window is sized after that charge.
        stop = at + meter.readable(Math.min(CHARGE_CHUNK, last + 1 - at), at) - 1
        chunk_from = at
        bits = 0_u64
        while at <= stop
          bits = table[bytes[at]]
          if width > 1
            bits &= table[256 + bytes[at + 1]]
            bits &= table[512 + bytes[at + 2]] if width > 2
          end
          break if bits != 0
          at += 1
        end
        if at <= stop
          meter.charge(at - chunk_from + 1, at)
          return at if accept?(at, meter, bits)
          at += 1
        elsif at > chunk_from
          meter.charge(at - chunk_from, chunk_from)
        end
      end
      meter.charge(@haystack.size - at, at) if at < @haystack.size
      -1
    end
  end
end
