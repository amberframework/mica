require "../../spec_helper"

# Builds Brotli streams (RFC 7932) bit by bit for the Mica::Brotli specs,
# including invalid ones: window bits, metablock headers, simple prefix
# codes and minimal compressed metablocks whose three prefix codes each
# have one symbol (and so take zero bits per symbol).
module BrotliStreams
  # Limits large enough that only a stream's validity decides the outcome.
  LIMITS = Mica::Brotli::DecodeLimits.custom(
    max_output_bytes: 1_073_741_824_i64,
    max_ratio: 1_000_000_000_i64,
    max_window_bytes: 16_777_216,
    max_metadata_bytes: 16_777_216,
  )

  # Writes bits least significant first, as Brotli packs them.
  class BitWriter
    def initialize
      @io = IO::Memory.new
      @current = 0_u32
      @used = 0
    end

    def bits(value : Int, count : Int) : self
      count.times do |bit|
        @current |= ((value.to_u64 >> bit) & 1).to_u32 << @used
        @used += 1
        flush_byte if @used == 8
      end
      self
    end

    # Pads with zero bits to a byte boundary.
    def align : self
      bits(0, 8 - @used) if @used > 0
      self
    end

    def bytes(data : Bytes) : self
      raise "unaligned" unless @used == 0
      @io.write(data)
      self
    end

    def to_slice : Bytes
      copy = IO::Memory.new
      copy.write(@io.to_slice)
      copy.write_byte(@current.to_u8) if @used > 0
      copy.to_slice
    end

    private def flush_byte : Nil
      @io.write_byte(@current.to_u8)
      @current = 0_u32
      @used = 0
    end
  end

  # WBITS (RFC 7932, section 9.1).
  def self.window(writer : BitWriter, window_bits : Int32) : Nil
    case window_bits
    when 16     then writer.bits(0, 1)
    when 17     then writer.bits(1, 1).bits(0, 3).bits(0, 3)
    when 18..24 then writer.bits(1, 1).bits(window_bits - 17, 3)
    else             writer.bits(1, 1).bits(0, 3).bits(window_bits - 8, 3)
    end
  end

  # A metablock header with MLEN *length* (1 to 2^24), using the fewest
  # nibbles unless *nibbles* is given.
  def self.metablock_header(writer : BitWriter, length : Int32, *, last : Bool, uncompressed : Bool = false,
                            nibbles : Int32? = nil) : Nil
    writer.bits(last ? 1 : 0, 1)
    writer.bits(0, 1) if last # ISLASTEMPTY
    value = length - 1
    count = nibbles || (value < (1 << 16) ? 4 : (value < (1 << 20) ? 5 : 6))
    writer.bits(count - 4, 2)
    count.times { |index| writer.bits((value >> (4 * index)) & 0xF, 4) }
    writer.bits(uncompressed ? 1 : 0, 1) unless last
  end

  # A simple prefix code (HSKIP 1) listing *symbols* of an alphabet whose
  # symbols take *symbol_bits* bits; four symbols use tree-select 0.
  def self.simple_code(writer : BitWriter, symbol_bits : Int32, symbols : Array(Int32)) : Nil
    writer.bits(1, 2)
    writer.bits(symbols.size - 1, 2)
    symbols.each { |symbol| writer.bits(symbol, symbol_bits) }
    writer.bits(0, 1) if symbols.size == 4
  end

  # The header of a compressed metablock with one block type per
  # category, NPOSTFIX 0, NDIRECT 0, context mode LSB6, one literal tree
  # and one distance tree, each prefix code a single symbol: *literal*,
  # the insert-and-copy *command* and the distance code *distance*.
  def self.trivial_compressed_header(writer : BitWriter, *, literal : Int32, command : Int32, distance : Int32) : Nil
    3.times { writer.bits(0, 1) } # NBLTYPESL, NBLTYPESI, NBLTYPESD = 1
    writer.bits(0, 2)             # NPOSTFIX
    writer.bits(0, 4)             # NDIRECT
    writer.bits(0, 2)             # context mode of literal block type 0
    writer.bits(0, 1)             # NTREESL = 1
    writer.bits(0, 1)             # NTREESD = 1
    simple_code(writer, 8, [literal])
    simple_code(writer, 10, [command])
    simple_code(writer, 6, [distance])
  end

  # The insert-and-copy symbol for insert length code *insert_code* and
  # copy length code *copy_code*, with an explicit distance.
  def self.command_symbol(insert_code : Int32, copy_code : Int32) : Int32
    cells = {
      {0, 0} => 128, {0, 8} => 192, {8, 0} => 256, {8, 8} => 320, {0, 16} => 384,
      {16, 0} => 448, {8, 16} => 512, {16, 8} => 576, {16, 16} => 640,
    }
    base = cells[{insert_code // 8 * 8, copy_code // 8 * 8}]
    base + (insert_code % 8) * 8 + copy_code % 8
  end

  # A stream of *metablocks* metablocks, each one literal 'a' and then a
  # copy of `metablock_bytes - 1` bytes at distance 1: a few bytes that
  # decode to `metablocks * metablock_bytes` bytes of 'a'.
  # *metablock_bytes* is 2,120 to 16,777,216 (the insert-and-copy command
  # uses insert code 1 and copy code 23).
  def self.repeat_bomb(metablocks : Int32, metablock_bytes : Int32, window_bits : Int32 = 22) : Bytes
    writer = BitWriter.new
    window(writer, window_bits)
    metablocks.times do |index|
      last = index == metablocks - 1
      metablock_header(writer, metablock_bytes, last: last)
      trivial_compressed_header(writer, literal: 'a'.ord, command: command_symbol(1, 23), distance: 16)
      writer.bits(metablock_bytes - 1 - 2118, 24) # copy length extra bits
      writer.bits(0, 1)                           # distance code 16, one extra bit: distance 1
    end
    writer.align
    writer.to_slice
  end

  # A stream of one uncompressed metablock holding *data*, then an empty
  # last metablock.
  def self.stored(data : Bytes, window_bits : Int32 = 16) : Bytes
    writer = BitWriter.new
    window(writer, window_bits)
    metablock_header(writer, data.size, last: false, uncompressed: true)
    writer.align
    writer.bytes(data)
    writer.bits(1, 1).bits(1, 1) # ISLAST, ISLASTEMPTY
    writer.align
    writer.to_slice
  end
end
