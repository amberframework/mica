module Mica::Encoding
  # Word-at-a-time helpers for the UTF-16 fast paths. Loads and stores go
  # through a fixed-size copy, which compiles to one unaligned move and
  # never assumes the pointer is aligned.

  # Reads the 8 bytes at *pointer* as a little-endian `UInt64`.
  # :nodoc:
  @[AlwaysInline]
  def self.load_u64_le(pointer : UInt8*) : UInt64
    value = uninitialized UInt64
    pointerof(value).as(UInt8*).copy_from(pointer, 8)
    value = value.byte_swap if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian
    value
  end

  # Writes *value* little-endian to the 4 bytes at *pointer*.
  # :nodoc:
  @[AlwaysInline]
  def self.store_u32_le(pointer : UInt8*, value : UInt32) : Nil
    value = value.byte_swap if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian
    pointer.copy_from(pointerof(value).as(UInt8*), 4)
  end

  # Writes *value* little-endian to the 8 bytes at *pointer*.
  # :nodoc:
  @[AlwaysInline]
  def self.store_u64_le(pointer : UInt8*, value : UInt64) : Nil
    value = value.byte_swap if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian
    pointer.copy_from(pointerof(value).as(UInt8*), 8)
  end

  # Swaps the two bytes of each 16-bit lane of *word*, turning four
  # big-endian code units into little-endian ones and back.
  # :nodoc:
  @[AlwaysInline]
  def self.swap_bytes_in_units(word : UInt64) : UInt64
    ((word & 0x00FF00FF00FF00FF_u64) << 8) | ((word >> 8) & 0x00FF00FF00FF00FF_u64)
  end

  # Spreads the low 4 bytes of *word* into four 16-bit lanes, one byte at
  # the bottom of each: four ASCII bytes become four little-endian code
  # units.
  # :nodoc:
  @[AlwaysInline]
  def self.widen_to_units(word : UInt64) : UInt64
    word = word & 0xFFFFFFFF_u64
    word = (word | (word << 16)) & 0x0000FFFF0000FFFF_u64
    (word | (word << 8)) & 0x00FF00FF00FF00FF_u64
  end

  # Packs the low byte of each of the four 16-bit lanes of *word* into a
  # `UInt32`: four ASCII code units become four bytes.
  # :nodoc:
  @[AlwaysInline]
  def self.narrow_units(word : UInt64) : UInt32
    narrowed = (word | (word >> 8)) & 0x0000FFFF0000FFFF_u64
    (narrowed | (narrowed >> 16)).to_u32!
  end

  # Writes the UTF-8 form of *unit*, a code point below U+10000 that is
  # not a surrogate, at *written* without branching on its length, and
  # returns the offset after it. Always stores 4 bytes: up to 3 bytes past
  # the returned offset are scratch, so *target* needs 4 bytes of room.
  # :nodoc:
  @[AlwaysInline]
  def self.put_bmp_utf8(target : UInt8*, written : Int32, unit : Int32) : Int32
    # All ones from 0x80 up and from 0x800 up, by sign: masks rather than
    # comparisons, so the compiler cannot turn the choice into a branch.
    at_least_two = (0x7F &- unit) >> 31
    at_least_three = (0x7FF &- unit) >> 31
    one = unit & ~at_least_two
    two = (0x80C0 | (unit >> 6) | ((unit & 0x3F) << 8)) & at_least_two & ~at_least_three
    three = (0x8080E0 | (unit >> 12) | (((unit >> 6) & 0x3F) << 8) | ((unit & 0x3F) << 16)) & at_least_three
    store_u32_le(target + written, (one | two | three).to_u32!)
    written &+ 1 &- at_least_two &- at_least_three
  end
end
