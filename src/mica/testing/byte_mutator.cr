module Mica::Testing
  # Seeded, replayable byte-level mutations for fuzzing any format.
  #
  # Every case is a pure function of `(seed, iteration)`, so a failure can
  # be replayed exactly with `case_bytes`. Mutations range from structural
  # (insert a format token, delete, duplicate, splice, truncate) to hostile
  # bytes: every class of invalid UTF-8, forbidden controls,
  # noncharacters, byte order marks in the wrong place, and re-encoding the
  # whole input (or only its tail) as UTF-16, UTF-32 or ISO-8859-1.
  #
  # A format supplies its seed documents and grammar tokens:
  #
  # ```
  # mutator = Mica::Testing::ByteMutator.new(
  #   list_of_seeds: ["<a/>".to_slice],
  #   list_of_tokens: ["<", "&amp;"].map(&.to_slice),
  # )
  # mutator.case_bytes(7_i64, 42) # => Bytes[...]
  # ```
  class ByteMutator
    # The hostile byte classes, each with sample sequences.
    HOSTILE = {
      "overlong"            => [Bytes[0xC0, 0x80], Bytes[0xC1, 0xBF], Bytes[0xE0, 0x80, 0x80], Bytes[0xE0, 0x9F, 0xBF], Bytes[0xF0, 0x80, 0x80, 0x80], Bytes[0xF0, 0x8F, 0xBF, 0xBF]],
      "surrogate"           => [Bytes[0xED, 0xA0, 0x80], Bytes[0xED, 0xBF, 0xBF], Bytes[0xED, 0xAF, 0xBF, 0xED, 0xB0, 0x80]],
      "above-10ffff"        => [Bytes[0xF4, 0x90, 0x80, 0x80], Bytes[0xF5, 0x80, 0x80, 0x80], Bytes[0xF7, 0xBF, 0xBF, 0xBF]],
      "five-six-byte"       => [Bytes[0xF8, 0x88, 0x80, 0x80, 0x80], Bytes[0xFB, 0xBF, 0xBF, 0xBF, 0xBF], Bytes[0xFC, 0x84, 0x80, 0x80, 0x80, 0x80], Bytes[0xFD, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF]],
      "fe-ff"               => [Bytes[0xFE], Bytes[0xFF], Bytes[0xFE, 0xFF], Bytes[0xFF, 0xFE]],
      "lone-continuation"   => [Bytes[0x80], Bytes[0xBF], Bytes[0x80, 0x80, 0x80]],
      "truncated"           => [Bytes[0xC3], Bytes[0xE2, 0x82], Bytes[0xF0, 0x9F, 0x98], Bytes[0xE2]],
      "nul"                 => [Bytes[0x00], Bytes[0x00, 0x00]],
      "c0-control"          => (0x01..0x1F).reject { |code| {0x09, 0x0A, 0x0D}.includes?(code) }.map { |code| Bytes[code.to_u8] },
      "del"                 => [Bytes[0x7F]],
      "c1-control"          => [Bytes[0xC2, 0x80], Bytes[0xC2, 0x84], Bytes[0xC2, 0x86], Bytes[0xC2, 0x9F]],
      "line-end"            => [Bytes[0x0D], Bytes[0x0D, 0x0A], Bytes[0xC2, 0x85], Bytes[0x0D, 0xC2, 0x85], Bytes[0xE2, 0x80, 0xA8], Bytes[0x0D, 0xE2, 0x80, 0xA8]],
      "noncharacter"        => [Bytes[0xEF, 0xBF, 0xBE], Bytes[0xEF, 0xBF, 0xBF], Bytes[0xF4, 0x8F, 0xBF, 0xBF], Bytes[0xEF, 0xB7, 0x90]],
      "byte-order-mark"     => [Bytes[0xEF, 0xBB, 0xBF], Bytes[0xFE, 0xFF], Bytes[0xFF, 0xFE], Bytes[0x00, 0x00, 0xFE, 0xFF], Bytes[0xFF, 0xFE, 0x00, 0x00]],
      "latin1-in-utf8"      => [Bytes[0xE9], Bytes[0x63, 0x61, 0x66, 0xE9], Bytes[0xA0]],
      "combining-character" => [Bytes[0xCC, 0x81], Bytes[0xE1, 0x85, 0xA1]],
    }

    # The flattened list of hostile sequences.
    HOSTILE_SEQUENCES = HOSTILE.values.flatten

    # Most mutations one case may receive.
    MAX_MUTATIONS = 64

    # Returns the seed inputs.
    getter list_of_seeds : Array(Bytes)

    # Returns the grammar tokens.
    getter list_of_tokens : Array(Bytes)

    def initialize(@list_of_seeds : Array(Bytes), @list_of_tokens : Array(Bytes) = [] of Bytes, @max_mutations : Int32 = 4)
      raise ArgumentError.new("ByteMutator needs at least one seed") if @list_of_seeds.empty?
      # Each mutation copies the case once, so the count stays small.
      unless 1 <= @max_mutations <= MAX_MUTATIONS
        raise ArgumentError.new("max_mutations must be 1 to #{MAX_MUTATIONS}")
      end
    end

    # Returns the bytes for case *iteration* under *seed*.
    def case_bytes(seed : Int64, iteration : Int32) : Bytes
      random = Random::PCG32.new(seed.to_u64!, iteration.to_u64)
      bytes = @list_of_seeds[random.rand(@list_of_seeds.size)].dup
      (1 + random.rand(@max_mutations)).times { bytes = mutate(bytes, random) }
      bytes = reencode(bytes, random) if random.rand(16) == 0
      bytes
    end

    # Applies one random mutation.
    def mutate(bytes : Bytes, random : Random) : Bytes
      return Bytes[0x3C] if bytes.empty?
      position = random.rand(bytes.size + 1)
      case random.rand(10)
      when 0 # flip one bit
        copy = bytes.dup
        index = random.rand(copy.size)
        copy[index] ^= (1_u8 << random.rand(8))
        copy
      when 1, 2 # insert a grammar token
        return insert(bytes, position, HOSTILE_SEQUENCES.sample(random)) if @list_of_tokens.empty?
        insert(bytes, position, @list_of_tokens.sample(random))
      when 3 # delete a range
        start = random.rand(bytes.size)
        remove(bytes, start, 1 + random.rand(Math.min(16, bytes.size - start)))
      when 4 # duplicate a range
        start = random.rand(bytes.size)
        length = 1 + random.rand(Math.min(32, bytes.size - start))
        insert(bytes, position, bytes[start, length].dup)
      when 5 # truncate
        bytes[0, random.rand(bytes.size)].dup
      when 6 # splice with another seed
        other = @list_of_seeds.sample(random)
        cut = other.empty? ? 0 : random.rand(other.size)
        head = Math.min(position, bytes.size)
        insert(bytes[0, head].dup, head, other[cut, other.size - cut])
      when 7, 8 # insert a hostile byte sequence
        insert(bytes, position, HOSTILE_SEQUENCES.sample(random))
      else # swap two bytes
        copy = bytes.dup
        first = random.rand(copy.size)
        second = random.rand(copy.size)
        copy[first], copy[second] = copy[second], copy[first]
        copy
      end
    end

    # Re-encodes the input, or only its tail (mixed encodings), as UTF-16,
    # UTF-32 or ISO-8859-1, with or without a byte order mark.
    def reencode(bytes : Bytes, random : Random) : Bytes
      split = random.rand(4) == 0 ? random.rand(bytes.size + 1) : 0
      head = bytes[0, split]
      tail = bytes[split, bytes.size - split]
      with_mark = split == 0 && random.rand(4) != 0
      encoded = case random.rand(5)
                when 0 then utf16(tail, big_endian: true, with_mark: with_mark)
                when 1 then utf16(tail, big_endian: false, with_mark: with_mark)
                when 2 then utf32(tail, big_endian: random.next_bool, with_mark: with_mark)
                when 3 then latin1(tail)
                else        utf16(tail, big_endian: random.next_bool, with_mark: with_mark, lone_surrogate: true)
                end
      concat(head, encoded)
    end

    # Encodes the valid UTF-8 in *bytes* as UTF-16; each invalid sequence
    # becomes a lone low surrogate. With *lone_surrogate* one extra high
    # surrogate is appended without its pair.
    def utf16(bytes : Bytes, big_endian : Bool, with_mark : Bool = true, lone_surrogate : Bool = false) : Bytes
      io = IO::Memory.new
      write_unit16(io, 0xFEFF, big_endian) if with_mark
      each_code_point(bytes) do |code|
        if code < 0
          write_unit16(io, 0xDC00, big_endian)
        elsif code >= 0x10000
          write_unit16(io, 0xD800 + ((code - 0x10000) >> 10), big_endian)
          write_unit16(io, 0xDC00 + ((code - 0x10000) & 0x3FF), big_endian)
        else
          write_unit16(io, code, big_endian)
        end
      end
      write_unit16(io, 0xD800, big_endian) if lone_surrogate
      io.to_slice
    end

    # Encodes the valid UTF-8 in *bytes* as UTF-32; each invalid sequence
    # becomes the out-of-range value 0x110000.
    def utf32(bytes : Bytes, big_endian : Bool, with_mark : Bool = true) : Bytes
      io = IO::Memory.new
      write_unit32(io, 0xFEFF, big_endian) if with_mark
      each_code_point(bytes) { |code| write_unit32(io, code < 0 ? 0x110000 : code, big_endian) }
      io.to_slice
    end

    # Encodes *bytes* as ISO-8859-1: code points up to U+00FF become one
    # byte, others become `?`.
    def latin1(bytes : Bytes) : Bytes
      io = IO::Memory.new
      each_code_point(bytes) { |code| io.write_byte(code >= 0 && code <= 0xFF ? code.to_u8 : '?'.ord.to_u8) }
      io.to_slice
    end

    # Yields each code point of *bytes*, or -1 for each invalid sequence
    # (which is skipped one byte at a time).
    private def each_code_point(bytes : Bytes, & : Int32 ->) : Nil
      index = 0
      while index < bytes.size
        code, length = Core::UTF8.decode(bytes[index, bytes.size - index])
        if length == 0
          yield -1
          index += 1
        else
          yield code
          index += length
        end
      end
    end

    private def write_unit16(io : IO, unit : Int32, big_endian : Bool) : Nil
      high = (unit >> 8).to_u8
      low = (unit & 0xFF).to_u8
      io.write(big_endian ? Bytes[high, low] : Bytes[low, high])
    end

    private def write_unit32(io : IO, unit : Int32, big_endian : Bool) : Nil
      parts = Bytes[(unit >> 24).to_u8!, (unit >> 16).to_u8!, (unit >> 8).to_u8!, unit.to_u8!]
      parts.reverse! unless big_endian
      io.write(parts)
    end

    # Returns *bytes* with *extra* inserted at *position*.
    def insert(bytes : Bytes, position : Int32, extra : Bytes) : Bytes
      position = Math.min(position, bytes.size)
      result = Bytes.new(bytes.size + extra.size)
      result[0, position].copy_from(bytes[0, position])
      result[position, extra.size].copy_from(extra)
      result[position + extra.size, bytes.size - position].copy_from(bytes[position, bytes.size - position])
      result
    end

    # Returns *bytes* without *length* bytes from *start*.
    def remove(bytes : Bytes, start : Int32, length : Int32) : Bytes
      length = Math.min(length, bytes.size - start)
      result = Bytes.new(bytes.size - length)
      result[0, start].copy_from(bytes[0, start])
      result[start, bytes.size - start - length].copy_from(bytes[start + length, bytes.size - start - length])
      result
    end

    private def concat(first : Bytes, second : Bytes) : Bytes
      insert(first, first.size, second)
    end
  end
end
