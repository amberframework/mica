# The differential fuzz harness for Mica::Deflate, Mica::Zlib and
# Mica::Gzip, shared by spec/deflate/differential_spec.cr,
# spec/deflate/bomb_spec.cr and fuzz/deflate_campaign.cr.
#
# Every case is one compressed input in one container (raw DEFLATE, zlib
# or gzip), built from a seed and an iteration number, so it replays as
# SEED:ITERATION. Four generator families make the cases:
#
# - structured: DEFLATE blocks written bit by bit (stored, fixed and
#   dynamic Huffman), covering every literal/length and distance code,
#   every extra-bit value, the repeat codes of the code-length alphabet
#   and each way a block header can be wrong;
# - compressed: data compressed by the system zlib at every level,
#   strategy, window size and memory level, with flushes and preset
#   dictionaries;
# - container: zlib and gzip headers and trailers written by hand around
#   either payload (every gzip flag combination, several members, each
#   header and trailer fault);
# - mutated: any of the above with bits flipped, bytes replaced, inserted
#   or deleted, truncated, spliced with another stream or followed by
#   trailing bytes.
#
# A trial decodes the case with Mica in one call and through the
# streaming Reader (over an IO that returns random chunk sizes, read
# through random slice sizes) and compares both with the system zlib
# (`DeflateOracle`): all three accept with identical bytes, or all three
# reject.
require "../src/mica"
require "./deflate_oracle"

module DeflateFuzz
  alias Format = DeflateOracle::Format

  # The generator families of the campaign summary.
  enum Family
    Structured
    Compressed
    Container
    Mutated
  end

  # One fuzz input. *is_meant_to_be_valid* is true when the generator
  # injected no fault, so the oracle must accept it.
  record Case, family : Family, format : Format, bytes : Bytes, dictionary : Bytes?, is_meant_to_be_valid : Bool

  # RFC 1951, section 3.2.5: base values and extra bits of length codes
  # 257..285 and distance codes 0..29.
  LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195,
                 227, 258]
  LENGTH_EXTRA  = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DISTANCE_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                   4097, 6145, 8193, 12_289, 16_385, 24_577]
  DISTANCE_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  # The order code-length code lengths are sent in (RFC 1951, section 3.2.7).
  CODE_LENGTH_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
  END_OF_BLOCK      =    256
  WINDOW_BYTES      = 32_768

  # The code lengths of the fixed Huffman block (RFC 1951, section 3.2.6).
  FIXED_LITERAL_LENGTHS  = Array.new(288) { |symbol| symbol < 144 ? 8 : (symbol < 256 ? 9 : (symbol < 280 ? 7 : 8)) }
  FIXED_DISTANCE_LENGTHS = Array.new(32, 5)

  # Writes DEFLATE's bit stream: fields least significant bit first,
  # Huffman codes most significant bit first.
  class BitWriter
    def initialize
      @io = IO::Memory.new
      @hold = 0_u64
      @held_bits = 0
    end

    # Appends the low *count* bits of *value* (at most 32).
    def bits(value : Int, count : Int32) : Nil
      return if count == 0
      @hold |= (value.to_u64! & ((1_u64 << count) - 1)) << @held_bits
      @held_bits += count
      while @held_bits >= 8
        @io.write_byte((@hold & 0xFF).to_u8)
        @hold >>= 8
        @held_bits -= 8
      end
    end

    # Appends a Huffman *code* of *length* bits.
    def code(code : Int, length : Int32) : Nil
      reversed = 0_u32
      length.times { |bit| reversed |= ((code.to_u32! >> bit) & 1) << (length - 1 - bit) }
      bits(reversed, length)
    end

    # Pads to the next byte boundary with the low bits of *padding*.
    def align(padding : Int = 0) : Nil
      bits(padding, 8 - @held_bits) if @held_bits > 0
    end

    # Appends whole bytes; the writer must be at a byte boundary.
    def bytes(slice : Bytes) : Nil
      raise ArgumentError.new("BitWriter#bytes needs a byte boundary") unless @held_bits == 0
      @io.write(slice)
    end

    # Returns the bits written since the last byte boundary.
    def held_bits : Int32
      @held_bits
    end

    # Returns the stream, the last byte padded with the low bits of *padding*.
    def to_slice(padding : Int = 0) : Bytes
      align(padding)
      @io.to_slice
    end
  end

  # A Huffman code: per-symbol code lengths and their canonical codes.
  struct HuffmanCode
    getter lengths : Array(Int32)
    getter codes : Array(UInt32)

    def initialize(@lengths : Array(Int32))
      @codes = DeflateFuzz.canonical_codes(@lengths)
    end

    # Appends *symbol*'s code to *writer*.
    def write(writer : BitWriter, symbol : Int32) : Nil
      writer.code(@codes[symbol], @lengths[symbol])
    end

    # Returns the symbols in *range* that have a code.
    def symbols_in(range : Range(Int32, Int32)) : Array(Int32)
      range.select { |symbol| symbol < @lengths.size && @lengths[symbol] > 0 }
    end
  end

  # Returns the canonical code of every symbol (RFC 1951, section 3.2.2).
  # An oversubscribed set of lengths still gets codes (cut to their
  # length), so a faulty header can be written out.
  def self.canonical_codes(lengths : Array(Int32)) : Array(UInt32)
    counts = Array.new(17, 0)
    lengths.each { |length| counts[length] += 1 }
    counts[0] = 0
    next_code = Array.new(17, 0_u32)
    code = 0_u32
    1.upto(16) do |bits|
      code = (code &+ counts[bits - 1]) << 1
      next_code[bits] = code
    end
    lengths.map do |length|
      next 0_u32 if length == 0
      assigned = next_code[length]
      next_code[length] = assigned &+ 1
      assigned & ((1_u32 << length) - 1)
    end
  end

  # Returns *count* code lengths of a complete Huffman code no longer than
  # *max_bits* (one length of 1 when *count* is 1). *is_skewed* grows one
  # long chain, so the longest codes appear.
  def self.complete_lengths(random : Random, count : Int32, max_bits : Int32, is_skewed : Bool = false) : Array(Int32)
    return [1] if count <= 1
    depths = [0]
    while depths.size < count
      index = is_skewed && random.rand(4) != 0 ? depths.size - 1 : random.rand(depths.size)
      if depths[index] >= max_bits
        start = random.rand(depths.size)
        index = (0...depths.size).map { |offset| (start + offset) % depths.size }.find! { |candidate| depths[candidate] < max_bits }
      end
      depth = depths[index] + 1
      depths[index] = depth
      depths << depth
    end
    depths
  end

  # One entry of a run-length encoded code length sequence: a code-length
  # symbol (0..18) and the value of its extra bits.
  record LengthSymbol, symbol : Int32, extra : Int32

  # Encodes *lengths* with the code-length alphabet. With *random*, runs
  # are cut at random places and sometimes sent plainly; without, every run
  # takes the longest repeat code that fits.
  def self.run_length_encode(lengths : Array(Int32), random : Random? = nil) : Array(LengthSymbol)
    list_of_symbols = [] of LengthSymbol
    index = 0
    previous = -1
    while index < lengths.size
      value = lengths[index]
      run = 1
      while index + run < lengths.size && lengths[index + run] == value
        run += 1
      end
      use_repeat = random.nil? || random.rand(5) != 0
      taken = 1
      if value == 0 && run >= 11 && use_repeat
        taken = repeat_count(random, 11, Math.min(run, 138))
        list_of_symbols << LengthSymbol.new(18, taken - 11)
      elsif value == 0 && run >= 3 && use_repeat
        taken = repeat_count(random, 3, Math.min(run, 10))
        list_of_symbols << LengthSymbol.new(17, taken - 3)
      elsif value == previous && run >= 3 && use_repeat
        taken = repeat_count(random, 3, Math.min(run, 6))
        list_of_symbols << LengthSymbol.new(16, taken - 3)
      else
        list_of_symbols << LengthSymbol.new(value, 0)
      end
      previous = value
      index += taken
    end
    list_of_symbols
  end

  private def self.repeat_count(random : Random?, least : Int32, most : Int32) : Int32
    return most if random.nil? || random.rand(2) == 0
    random.rand(least..most)
  end

  # Writes a dynamic block's code tables after the block header bits: HLIT,
  # HDIST, HCLEN, the code-length code *code_length_lengths* (19 lengths),
  # and *list_of_symbols* (see `run_length_encode`). *sent_code_lengths* is
  # the HCLEN count (4..19).
  def self.write_code_tables(writer : BitWriter, literal_count : Int32, distance_count : Int32,
                             code_length_lengths : Array(Int32), sent_code_lengths : Int32,
                             list_of_symbols : Array(LengthSymbol)) : Nil
    writer.bits(literal_count - 257, 5)
    writer.bits(distance_count - 1, 5)
    writer.bits(sent_code_lengths - 4, 4)
    sent_code_lengths.times { |index| writer.bits(code_length_lengths[CODE_LENGTH_ORDER[index]], 3) }
    code = HuffmanCode.new(code_length_lengths)
    list_of_symbols.each do |entry|
      code.write(writer, entry.symbol)
      case entry.symbol
      when 16 then writer.bits(entry.extra, 2)
      when 17 then writer.bits(entry.extra, 3)
      when 18 then writer.bits(entry.extra, 7)
      end
    end
  end

  # Writes the header of a dynamic block (after BFINAL and BTYPE) for the
  # given literal/length and distance code lengths, the plain way: longest
  # repeat codes and a complete code-length code. Returns the two codes.
  def self.write_dynamic_header(writer : BitWriter, literal_lengths : Array(Int32),
                                distance_lengths : Array(Int32)) : {HuffmanCode, HuffmanCode}
    list_of_symbols = run_length_encode(literal_lengths + distance_lengths)
    code_length_lengths = plain_code_length_lengths(list_of_symbols)
    sent = Math.max(4, 1 + CODE_LENGTH_ORDER.rindex! { |symbol| code_length_lengths[symbol] > 0 })
    write_code_tables(writer, literal_lengths.size, distance_lengths.size, code_length_lengths, sent, list_of_symbols)
    {HuffmanCode.new(literal_lengths), HuffmanCode.new(distance_lengths)}
  end

  # A complete code over the code-length symbols in use: the most frequent
  # get the shortest codes.
  private def self.plain_code_length_lengths(list_of_symbols : Array(LengthSymbol)) : Array(Int32)
    used = list_of_symbols.map(&.symbol).tally.to_a.sort_by! { |symbol, count| {-count, symbol} }.map(&.[0])
    used << (used[0] == 0 ? 1 : 0) if used.size == 1
    lengths = Array.new(19, 0)
    # A chain: 1, 2, 3, ... with the last two sharing the longest length.
    used.each_with_index do |symbol, rank|
      lengths[symbol] = Math.min(rank + 1, used.size - 1)
    end
    return lengths if lengths.max <= 7
    balanced = Array.new(19, 0)
    bits = 1
    while (1 << bits) < used.size
      bits += 1
    end
    short = (1 << bits) - used.size
    used.each_with_index { |symbol, rank| balanced[symbol] = rank < short ? bits - 1 : bits }
    balanced
  end

  # Wraps raw DEFLATE *raw* (which decodes to *data*) in a zlib container
  # (RFC 1950). Each named argument overrides one header or trailer field,
  # so a caller can write any fault.
  def self.zlib_stream(raw : Bytes, data : Bytes, *, window_code : Int32 = 7, level_code : Int32 = 2,
                       dictionary : Bytes? = nil, method : Int32 = 8, has_dictionary_flag : Bool = !dictionary.nil?,
                       check_delta : Int32 = 0, dictionary_id : UInt32? = nil, adler : UInt32? = nil,
                       trailer_bytes : Int32 = 4) : Bytes
    io = IO::Memory.new
    first = ((window_code & 0xF) << 4) | (method & 0xF)
    second = ((level_code & 3) << 6) | (has_dictionary_flag ? 0x20 : 0)
    remainder = ((first << 8) | second) % 31
    second |= (remainder == 0 ? 0 : 31 - remainder)
    second = (second & 0xE0) | ((second + check_delta) & 0x1F)
    io.write_byte(first.to_u8)
    io.write_byte(second.to_u8)
    if has_dictionary_flag
      id = dictionary_id || (dictionary ? DeflateOracle.adler32(dictionary) : 0_u32)
      io.write_bytes(id, IO::ByteFormat::BigEndian)
    end
    io.write(raw)
    trailer = IO::Memory.new
    trailer.write_bytes(adler || DeflateOracle.adler32(data), IO::ByteFormat::BigEndian)
    io.write(trailer.to_slice[0, trailer_bytes])
    io.to_slice
  end

  # Wraps raw DEFLATE *raw* (which decodes to *data*) in one gzip member
  # (RFC 1952). *extra*, *file_name* and *comment* set FEXTRA, FNAME and
  # FCOMMENT (the two strings get their NUL unless *is_terminated* is
  # false); the other arguments override single header and trailer fields.
  def self.gzip_member(raw : Bytes, data : Bytes, *, is_text : Bool = false, extra : Bytes? = nil,
                       file_name : Bytes? = nil, comment : Bytes? = nil, has_header_crc : Bool = false,
                       reserved_bits : Int32 = 0, method : Int32 = 8, magic : Bytes = Bytes[0x1F, 0x8B],
                       modification_time : UInt32 = 0_u32, extra_flags : UInt8 = 0_u8, operating_system : UInt8 = 255_u8,
                       is_terminated : Bool = true, header_crc_delta : Int32 = 0, crc : UInt32? = nil,
                       size : UInt32? = nil, trailer_bytes : Int32 = 8) : Bytes
    io = IO::Memory.new
    io.write(magic)
    io.write_byte(method.to_u8)
    flags = (is_text ? 1 : 0) | (has_header_crc ? 2 : 0) | (extra ? 4 : 0) | (file_name ? 8 : 0) | (comment ? 16 : 0)
    io.write_byte((flags | ((reserved_bits & 7) << 5)).to_u8)
    io.write_bytes(modification_time, IO::ByteFormat::LittleEndian)
    io.write_byte(extra_flags)
    io.write_byte(operating_system)
    if extra
      io.write_bytes(extra.size.to_u16, IO::ByteFormat::LittleEndian)
      io.write(extra)
    end
    [file_name, comment].each do |text|
      next unless text
      io.write(text)
      io.write_byte(0_u8) if is_terminated
    end
    if has_header_crc
      header_crc = (DeflateOracle.crc32(io.to_slice) & 0xFFFF) &+ header_crc_delta
      io.write_bytes(header_crc.to_u16!, IO::ByteFormat::LittleEndian)
    end
    io.write(raw)
    trailer = IO::Memory.new
    trailer.write_bytes(crc || DeflateOracle.crc32(data), IO::ByteFormat::LittleEndian)
    trailer.write_bytes(size || data.size.to_u32!, IO::ByteFormat::LittleEndian)
    io.write(trailer.to_slice[0, trailer_bytes])
    io.to_slice
  end

  # What the generators exercised, so a campaign can show that every code
  # was written at least once.
  class Coverage
    getter literal_symbols = Array(Int64).new(288, 0_i64)
    getter distance_symbols = Array(Int64).new(32, 0_i64)
    getter length_284_extras = Array(Int64).new(32, 0_i64)
    getter code_length_symbols = Array(Int64).new(19, 0_i64)
    getter block_types = Array(Int64).new(4, 0_i64)
    getter faults = Hash(String, Int64).new(0_i64)
    getter gzip_flag_sets = Array(Int64).new(256, 0_i64)

    def to_s(io : IO) : Nil
      io << "literal_length_codes=" << @literal_symbols.count(&.>(0)) << "/288"
      io << " distance_codes=" << @distance_symbols.count(&.>(0)) << "/32"
      io << " length_284_extras=" << @length_284_extras.count(&.>(0)) << "/32"
      io << " code_length_symbols=" << @code_length_symbols.count(&.>(0)) << "/19"
      io << " block_types=" << @block_types.count(&.>(0)) << "/4"
      io << " gzip_flag_sets=" << (0...32).count { |flags| @gzip_flag_sets[flags] > 0 } << "/32"
      io << " fault_kinds=" << @faults.size
    end
  end

  # How large the cases of a run may get. The campaign uses `FULL`; the
  # spec's slice uses `QUICK`, which keeps the same generators and shapes
  # with smaller data.
  record Profile, largest_data_bytes : Int32, largest_structured_output : Int32 do
    FULL  = new(400_000, 300_000)
    QUICK = new(70_000, 70_000)
  end

  # The state of one structured stream while it is written: how many
  # output bytes exist so far (the history a distance may reach), the
  # faults still to inject, and the output still allowed.
  private class StreamPlan
    property history : Int32
    getter? is_valid = true
    getter coverage : Coverage?
    property output_budget : Int32

    def initialize(@random : Random, @faults_left : Int32, @history : Int32, @output_budget : Int32, @coverage : Coverage?)
    end

    # Returns true when the caller should inject the fault *name* here.
    def fault?(name : String, one_in : Int32) : Bool
      return false if @faults_left == 0 || @random.rand(one_in) != 0
      @faults_left -= 1
      @is_valid = false
      if coverage = @coverage
        coverage.faults[name] += 1
      end
      true
    end

    def faults_left? : Bool
      @faults_left > 0
    end

    # The farthest a distance may reach back.
    def reach : Int32
      Math.min(@history, WINDOW_BYTES)
    end

    def produced(count : Int32) : Nil
      @history += count
      @output_budget -= count
    end
  end

  # Returns a raw DEFLATE stream written block by block. The second value
  # is true when no fault was injected (the stream must be valid).
  # *history* is the size of a preset dictionary the stream may reach into.
  def self.structured_stream(random : Random, profile : Profile, coverage : Coverage? = nil, history : Int32 = 0,
                             fault_count : Int32? = nil) : {Bytes, Bool}
    faults = fault_count || (random.rand(10) < 3 ? 1 + random.rand(2) : 0)
    budget = case random.rand(100)
             when 0...70  then 1 + random.rand(2_000)
             when 70...97 then 1 + random.rand(20_000)
             else              1 + random.rand(profile.largest_structured_output)
             end
    plan = StreamPlan.new(random, faults, history, budget, coverage)
    writer = BitWriter.new
    block_count = case random.rand(20)
                  when 0...9   then 1
                  when 9...17  then 2 + random.rand(4)
                  when 17...19 then 6 + random.rand(40)
                  else              50 + random.rand(400)
                  end
    is_run_of_empty_blocks = block_count >= 50
    block_count.times do |index|
      is_last = index == block_count - 1
      is_final = is_last
      is_final = false if is_last && plan.fault?("missing final block", 8)
      is_final = true if !is_last && plan.fault?("final block in the middle", 30 * block_count)
      writer.bits(is_final ? 1 : 0, 1)
      write_block(writer, random, plan, is_run_of_empty_blocks)
    end
    {writer.to_slice(random.rand(256)), plan.is_valid?}
  end

  private def self.write_block(writer : BitWriter, random : Random, plan : StreamPlan, is_empty : Bool) : Nil
    type = random.rand(10)
    type = type < 2 ? 0 : (type < 5 ? 1 : 2)
    type = 3 if plan.fault?("reserved block type", 40)
    if coverage = plan.coverage
      coverage.block_types[type] += 1
    end
    writer.bits(type, 2)
    token_count = is_empty ? 0 : (random.rand(4) == 0 ? random.rand(8) : random.rand(600))
    case type
    when 0
      write_stored_block(writer, random, plan, is_empty)
    when 1
      write_tokens(writer, random, plan, HuffmanCode.new(FIXED_LITERAL_LENGTHS), HuffmanCode.new(FIXED_DISTANCE_LENGTHS),
        token_count, is_fixed: true)
    when 2
      literal, distance = write_random_dynamic_header(writer, random, plan)
      write_tokens(writer, random, plan, literal, distance, token_count, is_fixed: false)
    else
      writer.bits(random.rand(1 << 16), 16)
    end
  end

  private def self.write_stored_block(writer : BitWriter, random : Random, plan : StreamPlan, is_empty : Bool) : Nil
    size = case random.rand(20)
           when 0...6   then 0
           when 6...14  then random.rand(64)
           when 14...19 then random.rand(3_000)
           else              random.rand(2) == 0 ? 65_535 : random.rand(65_536)
           end
    size = 0 if is_empty
    size = Math.min(size, Math.max(plan.output_budget, 0))
    writer.align(random.rand(256))
    complement = size ^ 0xFFFF
    complement ^= 1 << random.rand(16) if plan.fault?("stored length mismatch", 12)
    writer.bits(size, 16)
    writer.bits(complement, 16)
    data = random.rand(3) == 0 ? Bytes.new(size, random.rand(256).to_u8) : random.random_bytes(size)
    writer.bytes(data)
    plan.produced(size)
  end

  # Picks code lengths for the literal/length and distance alphabets,
  # injects at most one header fault, and writes the header with random
  # repeat codes and a random code-length code.
  private def self.write_random_dynamic_header(writer : BitWriter, random : Random, plan : StreamPlan) : {HuffmanCode, HuffmanCode}
    literal_lengths = random_literal_lengths(random)
    distance_lengths = random_distance_lengths(random)
    apply_tree_faults(random, plan, literal_lengths, distance_lengths)
    literal_count = sent_count(random, literal_lengths, 257, 286)
    distance_count = sent_count(random, distance_lengths, 1, 30)
    literal_count = 287 + random.rand(2) if plan.fault?("HLIT past 286", 60)
    distance_count = 31 + random.rand(2) if plan.fault?("HDIST past 30", 60)
    sent_literals = Array.new(literal_count) { |symbol| literal_lengths[symbol]? || random.rand(3) }
    sent_distances = Array.new(distance_count) { |symbol| distance_lengths[symbol]? || random.rand(3) }
    all_lengths = sent_literals + sent_distances
    list_of_symbols = if plan.fault?("repeat past the last length", 60)
                        kept = all_lengths.size - 1 - random.rand(Math.min(all_lengths.size, 100))
                        run_length_encode(all_lengths[0, kept], random) << LengthSymbol.new(18, 127)
                      else
                        run_length_encode(all_lengths, random)
                      end
    list_of_symbols.unshift(LengthSymbol.new(16, random.rand(4))) if plan.fault?("repeat with no previous length", 60)
    code_length_lengths = random_code_length_lengths(random, plan, list_of_symbols)
    last_sent = CODE_LENGTH_ORDER.rindex { |symbol| code_length_lengths[symbol] > 0 } || 0
    sent = Math.max(4, last_sent + 1)
    sent += random.rand(20 - sent) if random.rand(3) == 0
    if coverage = plan.coverage
      list_of_symbols.each { |entry| coverage.code_length_symbols[entry.symbol] += 1 }
    end
    write_code_tables(writer, literal_count, distance_count, code_length_lengths, sent, list_of_symbols)
    {HuffmanCode.new(sent_literals), HuffmanCode.new(sent_distances)}
  end

  # The transmitted count of an alphabet: up to its last used symbol, at
  # least *least*, sometimes padded with unused symbols up to *most*.
  private def self.sent_count(random : Random, lengths : Array(Int32), least : Int32, most : Int32) : Int32
    count = Math.max(least, 1 + (lengths.rindex(&.>(0)) || -1))
    count += random.rand(most - count + 1) if random.rand(3) == 0
    count
  end

  private def self.random_literal_lengths(random : Random) : Array(Int32)
    lengths = Array.new(286, 0)
    used = case random.rand(8)
           when 0, 1 then (0...286).to_a
           when 2    then [END_OF_BLOCK]
           when 3    then ([END_OF_BLOCK] + Array.new(1 + random.rand(3)) { random.rand(286) }).uniq!
           else
             literal_share = 1 + random.rand(100)
             length_share = random.rand(101)
             (0...286).select do |symbol|
               symbol == END_OF_BLOCK || random.rand(100) < (symbol < END_OF_BLOCK ? literal_share : length_share)
             end
           end
    assign_lengths(random, lengths, used, 15)
    lengths
  end

  private def self.random_distance_lengths(random : Random) : Array(Int32)
    lengths = Array.new(30, 0)
    used = case random.rand(8)
           when 0, 1, 2 then (0...30).to_a
           when 3       then [] of Int32
           when 4       then [random.rand(30)]
           else
             share = 1 + random.rand(100)
             (0...30).select { random.rand(100) < share }
           end
    assign_lengths(random, lengths, used, 15)
    lengths
  end

  # Gives *used* symbols the lengths of a complete code: in random order,
  # or sorted so that equal lengths sit in long runs (for repeat code 16).
  private def self.assign_lengths(random : Random, lengths : Array(Int32), used : Array(Int32), max_bits : Int32) : Nil
    return if used.empty?
    list_of_lengths = complete_lengths(random, used.size, max_bits, is_skewed: random.rand(3) == 0)
    case random.rand(3)
    when 0 then list_of_lengths.shuffle!(random)
    when 1 then list_of_lengths.sort!
    end
    used.each_with_index { |symbol, index| lengths[symbol] = list_of_lengths[index] }
  end

  private def self.apply_tree_faults(random : Random, plan : StreamPlan, literal_lengths : Array(Int32),
                                     distance_lengths : Array(Int32)) : Nil
    return unless plan.faults_left?
    if plan.fault?("incomplete literal/length code", 50)
      make_incomplete(random, literal_lengths)
    elsif plan.fault?("oversubscribed literal/length code", 50)
      make_oversubscribed(random, literal_lengths)
    elsif plan.fault?("no end-of-block code", 50)
      literal_lengths[END_OF_BLOCK] = 0
      literal_lengths[random.rand(256)] = 1 + random.rand(15) if random.rand(2) == 0
    elsif plan.fault?("empty literal/length code", 80)
      literal_lengths.fill(0)
    elsif plan.fault?("single literal/length code longer than one bit", 80)
      literal_lengths.fill(0)
      literal_lengths[END_OF_BLOCK] = 2 + random.rand(14)
    elsif plan.fault?("incomplete distance code", 50)
      make_incomplete(random, distance_lengths)
    elsif plan.fault?("oversubscribed distance code", 50)
      make_oversubscribed(random, distance_lengths)
    elsif plan.fault?("single distance code longer than one bit", 80)
      distance_lengths.fill(0)
      distance_lengths[random.rand(30)] = 2 + random.rand(14)
    end
  end

  private def self.make_incomplete(random : Random, lengths : Array(Int32)) : Nil
    used = (0...lengths.size).select { |symbol| lengths[symbol] > 0 && symbol != END_OF_BLOCK }
    if used.empty?
      lengths[random.rand(lengths.size)] = 2 + random.rand(6)
    elsif random.rand(2) == 0
      lengths[used.sample(random)] = 0
    else
      symbol = used.sample(random)
      lengths[symbol] = Math.min(15, lengths[symbol] + 1 + random.rand(3))
      lengths[symbol] = 14 if lengths[symbol] == 15 && used.size == 1
    end
  end

  private def self.make_oversubscribed(random : Random, lengths : Array(Int32)) : Nil
    long = (0...lengths.size).select { |symbol| lengths[symbol] > 1 }
    unused = (0...lengths.size).select { |symbol| lengths[symbol] == 0 }
    if !long.empty? && (unused.empty? || random.rand(2) == 0)
      symbol = long.sample(random)
      lengths[symbol] -= 1
    elsif !unused.empty?
      lengths[unused.sample(random)] = 1 + random.rand(Math.max(1, lengths.max))
    end
  end

  private def self.random_code_length_lengths(random : Random, plan : StreamPlan, list_of_symbols : Array(LengthSymbol)) : Array(Int32)
    used = list_of_symbols.map(&.symbol).uniq!
    used << (0...19).find! { |symbol| !used.includes?(symbol) } if used.size == 1
    lengths = Array.new(19, 0)
    if plan.fault?("incomplete code-length code", 60)
      list_of_lengths = complete_lengths(random, used.size + 1, 7).shuffle!(random)
      used.each_with_index { |symbol, index| lengths[symbol] = list_of_lengths[index] }
    else
      assign_lengths(random, lengths, used, 7)
    end
    if plan.fault?("oversubscribed code-length code", 60)
      make_oversubscribed(random, lengths)
      lengths.map! { |length| Math.min(length, 7) }
    elsif plan.fault?("empty code-length code", 120)
      lengths.fill(0)
    end
    lengths
  end

  # Writes *count* literals and matches with the given codes, then the
  # end-of-block code. Matches reach back at most to the start of the
  # output unless a fault says otherwise.
  private def self.write_tokens(writer : BitWriter, random : Random, plan : StreamPlan, literal : HuffmanCode,
                                distance : HuffmanCode, count : Int32, is_fixed : Bool) : Nil
    list_of_literals = literal.symbols_in(0..255)
    list_of_lengths = literal.symbols_in(257..285)
    list_of_distances = distance.symbols_in(0..29)
    match_share = random.rand(100)
    count.times do
      break if plan.output_budget <= 0
      if is_fixed && plan.fault?("literal/length code 286 or 287", 2_000)
        literal.write(writer, 286 + random.rand(2))
        cover_literal(plan, 286)
        cover_literal(plan, 287)
        return
      end
      wants_match = !list_of_lengths.empty? && (list_of_literals.empty? || random.rand(100) < match_share)
      if wants_match
        break unless write_match(writer, random, plan, literal, distance, list_of_lengths, list_of_distances, is_fixed)
      elsif list_of_literals.empty?
        break
      else
        symbol = list_of_literals.sample(random)
        literal.write(writer, symbol)
        cover_literal(plan, symbol)
        plan.produced(1)
      end
    end
    return if plan.fault?("missing end-of-block code", 400)
    return unless literal.lengths[END_OF_BLOCK] > 0
    literal.write(writer, END_OF_BLOCK)
    cover_literal(plan, END_OF_BLOCK)
  end

  private def self.cover_literal(plan : StreamPlan, symbol : Int32) : Nil
    if coverage = plan.coverage
      coverage.literal_symbols[symbol] += 1
    end
  end

  # Writes one length and distance pair. Returns false when the block
  # must end here (an invalid code was written on purpose, or no match is
  # possible).
  private def self.write_match(writer : BitWriter, random : Random, plan : StreamPlan, literal : HuffmanCode,
                               distance : HuffmanCode, list_of_lengths : Array(Int32), list_of_distances : Array(Int32),
                               is_fixed : Bool) : Bool
    length_symbol = list_of_lengths.sample(random)
    length_extra = random.rand(1 << LENGTH_EXTRA[length_symbol - 257])
    if is_fixed && plan.fault?("distance code 30 or 31", 2_000)
      write_length(writer, plan, literal, length_symbol, length_extra)
      invalid = 30 + random.rand(2)
      distance.write(writer, invalid)
      if coverage = plan.coverage
        coverage.distance_symbols[invalid] += 1
      end
      return false
    end
    reach = plan.reach
    if list_of_distances.empty?
      return false unless plan.fault?("distance with an empty distance code", 20)
      write_length(writer, plan, literal, length_symbol, length_extra)
      writer.bits(random.rand(1 << 15), 15)
      return false
    end
    if list_of_distances.size == 1 && distance.lengths[list_of_distances[0]] == 1 &&
       plan.fault?("unused code of a single-code distance tree", 20)
      write_length(writer, plan, literal, length_symbol, length_extra)
      writer.bits(1, 1)
      return false
    end
    if plan.fault?("distance too far back", 300)
      list_of_far_symbols = list_of_distances.select { |candidate| DISTANCE_BASE[candidate] + (1 << DISTANCE_EXTRA[candidate]) - 1 > reach }
      unless list_of_far_symbols.empty?
        symbol = list_of_far_symbols.sample(random)
        write_length(writer, plan, literal, length_symbol, length_extra)
        least_extra = Math.max(0, reach + 1 - DISTANCE_BASE[symbol])
        extra = least_extra + random.rand((1 << DISTANCE_EXTRA[symbol]) - least_extra)
        write_distance(writer, plan, distance, symbol, extra)
        return false
      end
    end
    list_of_near_symbols = list_of_distances.select { |candidate| DISTANCE_BASE[candidate] <= reach }
    return false if list_of_near_symbols.empty?
    symbol = list_of_near_symbols.sample(random)
    extra = Math.min(random.rand(1 << DISTANCE_EXTRA[symbol]), reach - DISTANCE_BASE[symbol])
    # The longest distances are rare by chance: ask for them now and then.
    extra = Math.min((1 << DISTANCE_EXTRA[symbol]) - 1, reach - DISTANCE_BASE[symbol]) if random.rand(8) == 0
    write_length(writer, plan, literal, length_symbol, length_extra)
    write_distance(writer, plan, distance, symbol, extra)
    plan.produced(length_symbol == 285 ? 258 : LENGTH_BASE[length_symbol - 257] + length_extra)
    true
  end

  private def self.write_length(writer : BitWriter, plan : StreamPlan, literal : HuffmanCode, symbol : Int32, extra : Int32) : Nil
    literal.write(writer, symbol)
    writer.bits(extra, LENGTH_EXTRA[symbol - 257])
    if coverage = plan.coverage
      coverage.literal_symbols[symbol] += 1
      coverage.length_284_extras[extra] += 1 if symbol == 284
    end
  end

  private def self.write_distance(writer : BitWriter, plan : StreamPlan, distance : HuffmanCode, symbol : Int32, extra : Int32) : Nil
    distance.write(writer, symbol)
    writer.bits(extra, DISTANCE_EXTRA[symbol])
    if coverage = plan.coverage
      coverage.distance_symbols[symbol] += 1
    end
  end

  WORDS = %w(the quick brown fox jumps over lazy dog Mica inflate deflate window Huffman 0123456789 <html> </html>
    Content-Encoding gzip {"id": "name": null true false \r\n \t = ; , . amber crystal)

  # Returns *size* bytes of one of several kinds of data: random, text
  # made of a small vocabulary, runs, zeros, a small alphabet, or a block
  # repeated at a fixed period (up to the window size and just past it).
  def self.sample_data(random : Random, size : Int32) : Bytes
    case random.rand(8)
    when 0
      random.random_bytes(size)
    when 1, 2
      io = IO::Memory.new(size)
      while io.pos < size
        io << WORDS.sample(random)
        io << ' ' if random.rand(3) != 0
      end
      io.to_slice[0, size]
    when 3
      data = Bytes.new(size)
      index = 0
      while index < size
        run = Math.min(1 + random.rand(random.rand(4) == 0 ? 2_000 : 40), size - index)
        data[index, run].fill(random.rand(256).to_u8)
        index += run
      end
      data
    when 4
      Bytes.new(size, random.rand(4) == 0 ? random.rand(256).to_u8 : 0_u8)
    when 5
      alphabet = 2 + random.rand(6)
      Bytes.new(size) { (97 + random.rand(alphabet)).to_u8 }
    else
      period = case random.rand(6)
               when 0 then WINDOW_BYTES
               when 1 then WINDOW_BYTES - 1 - random.rand(3)
               when 2 then WINDOW_BYTES + 1 + random.rand(300)
               else        1 + random.rand(5_000)
               end
      block = random.random_bytes(Math.min(period, Math.max(size, 1)))
      Bytes.new(size) { |index| block[index % block.size] }
    end
  end

  private def self.data_size(random : Random, profile : Profile) : Int32
    case random.rand(100)
    when 0...4   then 0
    when 4...60  then 1 + random.rand(2_000)
    when 60...90 then 2_000 + random.rand(18_000)
    when 90...98 then 20_000 + random.rand(Math.min(80_000, profile.largest_data_bytes - 20_000))
    else              20_000 + random.rand(profile.largest_data_bytes - 20_000)
    end
  end

  private def self.random_steps(random : Random, size : Int32) : Array(DeflateOracle::Step)
    return [] of DeflateOracle::Step if random.rand(5) < 3
    flushes = [DeflateOracle::Flush::None, DeflateOracle::Flush::Partial, DeflateOracle::Flush::Sync,
               DeflateOracle::Flush::Full, DeflateOracle::Flush::Block]
    Array.new(1 + random.rand(6)) { DeflateOracle::Step.new(random.rand(size // 2 + 2), flushes.sample(random)) }
  end

  # Returns data and its compression by the system zlib as raw DEFLATE,
  # with random level, strategy, window bits, memory level and flushes.
  def self.compressed_payload(random : Random, profile : Profile, dictionary : Bytes? = nil,
                              format : Format = Format::Raw) : {Bytes, Bytes}
    data = sample_data(random, data_size(random, profile))
    if dictionary && random.rand(2) == 0 && !dictionary.empty?
      # Data made of dictionary pieces, so matches reach into the dictionary.
      io = IO::Memory.new
      while io.pos < data.size
        start = random.rand(dictionary.size)
        io.write(dictionary[start, Math.min(dictionary.size - start, 3 + random.rand(200))])
      end
      data = io.to_slice[0, data.size]
    end
    compressed = DeflateOracle.compress(data, format, level: random.rand(10),
      strategy: DeflateOracle::Strategy.values.sample(random), window_bits: 9 + random.rand(7),
      memory_level: 1 + random.rand(9), steps: random_steps(random, data.size), dictionary: dictionary)
    {data, compressed}
  end

  private def self.random_dictionary(random : Random) : Bytes
    size = case random.rand(10)
           when 0 then 1 + random.rand(8)
           when 1 then WINDOW_BYTES + random.rand(8_000)
           when 2 then WINDOW_BYTES - random.rand(3)
           else        1 + random.rand(4_000)
           end
    sample_data(random, size)
  end

  # A structured raw stream and what the oracle decodes it to (every byte
  # zlib produced when the stream is faulty), for the containers'
  # checksums.
  private def self.structured_payload(random : Random, profile : Profile, coverage : Coverage?, dictionary : Bytes?,
                                      fault_count : Int32? = nil) : {Bytes, Bytes, Bool}
    history = dictionary ? Math.min(dictionary.size, WINDOW_BYTES) : 0
    raw, is_valid = structured_stream(random, profile, coverage, history, fault_count)
    result = DeflateOracle.decode(Format::Raw, raw, dictionary)
    {raw, result.output, is_valid}
  end

  # Returns the random source of the case *iteration* of the run *seed*.
  # *purpose* separates the generator (0) from the trial's chunk sizes (1).
  # Seed and iteration are hashed first (the SplitMix64 finalizer), so
  # neighboring seeds and iterations share nothing.
  def self.random_for(seed : Int64, iteration : Int32, purpose : Int32 = 0) : Random::PCG32
    state = scramble(seed.to_u64! ^ scramble(iteration.to_u64! &+ (purpose.to_u64! << 40)))
    Random::PCG32.new(state, scramble(state ^ 0x9E3779B97F4A7C15_u64))
  end

  private def self.scramble(value : UInt64) : UInt64
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9_u64
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB_u64
    value ^ (value >> 31)
  end

  # Builds the case *iteration* of the run *seed*.
  def self.case_for(seed : Int64, iteration : Int32, profile : Profile = Profile::FULL, coverage : Coverage? = nil) : Case
    random = random_for(seed, iteration)
    case random.rand(100)
    when 0...30  then structured_case(random, profile, coverage)
    when 30...55 then compressed_case(random, profile)
    when 55...75 then container_case(random, profile, coverage)
    else              mutated_case(random, profile, coverage)
    end
  end

  private def self.random_format(random : Random) : Format
    Format.values.sample(random)
  end

  # Hand-written blocks in a clean container.
  private def self.structured_case(random : Random, profile : Profile, coverage : Coverage?) : Case
    format = random.rand(2) == 0 ? Format::Raw : random_format(random)
    dictionary = format.zlib? && random.rand(4) == 0 ? random_dictionary(random) : nil
    raw, data, is_valid = structured_payload(random, profile, coverage, dictionary)
    bytes = if format.raw?
              raw
            elsif format.zlib?
              zlib_stream(raw, data, window_code: random.rand(8), level_code: random.rand(4), dictionary: dictionary)
            else
              gzip_member(raw, data)
            end
    Case.new(Family::Structured, format, bytes, dictionary, is_valid)
  end

  # Streams the system zlib wrote, container included.
  private def self.compressed_case(random : Random, profile : Profile) : Case
    format = random_format(random)
    dictionary = format.zlib? && random.rand(4) == 0 ? random_dictionary(random) : nil
    _, bytes = compressed_payload(random, profile, dictionary, format)
    Case.new(Family::Compressed, format, bytes, dictionary, true)
  end

  # A raw payload of either kind, for a hand-written container.
  private def self.any_payload(random : Random, profile : Profile, coverage : Coverage?, dictionary : Bytes?) : {Bytes, Bytes, Bool}
    if random.rand(2) == 0
      structured_payload(random, profile, coverage, dictionary, fault_count: 0)
    else
      data, raw = compressed_payload(random, profile, dictionary)
      {raw, data, true}
    end
  end

  # Hand-written zlib and gzip containers with every header variation,
  # four in ten with one fault.
  private def self.container_case(random : Random, profile : Profile, coverage : Coverage?) : Case
    fault = random.rand(10) < 4 ? random.rand(100) : -1
    if random.rand(5) < 2
      zlib_container_case(random, profile, coverage, fault)
    else
      gzip_container_case(random, profile, coverage, fault)
    end
  end

  private def self.note_fault(coverage : Coverage?, name : String) : Nil
    coverage.faults[name] += 1 if coverage
  end

  private def self.zlib_container_case(random : Random, profile : Profile, coverage : Coverage?, fault : Int32) : Case
    dictionary = random.rand(3) == 0 ? random_dictionary(random) : nil
    raw, data, is_valid = any_payload(random, profile, coverage, dictionary)
    window_code = random.rand(8)
    level_code = random.rand(4)
    given_dictionary = dictionary
    bytes = case fault
            when 0...12
              note_fault(coverage, "zlib header check")
              zlib_stream(raw, data, window_code: window_code, level_code: level_code, dictionary: dictionary,
                check_delta: 1 + random.rand(30))
            when 12...24
              note_fault(coverage, "zlib compression method")
              zlib_stream(raw, data, window_code: window_code, dictionary: dictionary,
                method: ((0..15).to_a - [8]).sample(random))
            when 24...36
              note_fault(coverage, "zlib window size past 32 KiB")
              zlib_stream(raw, data, window_code: 8 + random.rand(8), dictionary: dictionary)
            when 36...46
              note_fault(coverage, "zlib FDICT without a dictionary")
              given_dictionary = nil
              zlib_stream(raw, data, window_code: window_code, dictionary: dictionary, has_dictionary_flag: true,
                dictionary_id: dictionary ? nil : random.rand(UInt32))
            when 46...56
              note_fault(coverage, "zlib wrong dictionary")
              given_dictionary = random_dictionary(random)
              zlib_stream(raw, data, window_code: window_code, dictionary: dictionary || random_dictionary(random))
            when 56...64
              note_fault(coverage, "zlib dictionary given, FDICT clear")
              given_dictionary = dictionary || random_dictionary(random)
              zlib_stream(raw, data, window_code: window_code, dictionary: dictionary, has_dictionary_flag: false)
            when 64...84
              note_fault(coverage, "zlib Adler-32")
              zlib_stream(raw, data, window_code: window_code, dictionary: dictionary,
                adler: DeflateOracle.adler32(data) ^ (1_u32 << random.rand(32)))
            when 84...100
              note_fault(coverage, "zlib short trailer")
              zlib_stream(raw, data, window_code: window_code, dictionary: dictionary, trailer_bytes: random.rand(4))
            else
              zlib_stream(raw, data, window_code: window_code, level_code: level_code, dictionary: dictionary)
            end
    Case.new(Family::Container, Format::Zlib, bytes, given_dictionary, is_valid && fault < 0)
  end

  private def self.random_text(random : Random) : Bytes
    size = random.rand(20) == 0 ? random.rand(3_000) : random.rand(40)
    Bytes.new(size) { (1 + random.rand(255)).to_u8 }
  end

  private def self.random_extra(random : Random) : Bytes
    size = case random.rand(20)
           when 0     then 65_535
           when 1, 2  then random.rand(5_000)
           when 3...8 then 0
           else            random.rand(300)
           end
    random.random_bytes(size)
  end

  private def self.gzip_container_case(random : Random, profile : Profile, coverage : Coverage?, fault : Int32) : Case
    member_count = case random.rand(10)
                   when 0...6 then 1
                   when 6...9 then 2 + random.rand(4)
                   else            6 + random.rand(60)
                   end
    faulty_member = fault >= 0 ? random.rand(member_count) : -1
    is_valid = true
    io = IO::Memory.new
    member_count.times do |index|
      raw, data, is_payload_valid = member_count > 6 ? {Bytes[0x03, 0x00], Bytes.empty, true} : any_payload(random, profile, coverage, nil)
      is_valid &&= is_payload_valid
      flags = random.rand(32)
      coverage.gzip_flag_sets[flags] += 1 if coverage
      io.write(random_gzip_member(random, raw, data, flags, index == faulty_member ? fault : -1, coverage))
      next unless index == faulty_member && fault >= 90
      note_fault(coverage, "bytes between or after gzip members")
      io.write(random.rand(2) == 0 ? Bytes.new(1 + random.rand(8)) : random.random_bytes(1 + random.rand(8)))
    end
    Case.new(Family::Container, Format::Gzip, io.to_slice, nil, is_valid && fault < 0)
  end

  private def self.random_gzip_member(random : Random, raw : Bytes, data : Bytes, flags : Int32, fault : Int32,
                                      coverage : Coverage?) : Bytes
    is_text = flags & 1 != 0
    has_header_crc = flags & 2 != 0
    extra = flags & 4 != 0 ? random_extra(random) : nil
    file_name = flags & 8 != 0 ? random_text(random) : nil
    comment = flags & 16 != 0 ? random_text(random) : nil
    modification_time = random.rand(UInt32)
    extra_flags = random.rand(256).to_u8
    operating_system = random.rand(256).to_u8
    case fault
    when 0...8
      note_fault(coverage, "gzip magic")
      magic = random.rand(2) == 0 ? Bytes[0x1F, random.rand(256).to_u8] : Bytes[random.rand(256).to_u8, 0x8B]
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: has_header_crc, magic: magic)
    when 8...16
      note_fault(coverage, "gzip compression method")
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: has_header_crc, method: ((0..255).to_a - [8]).sample(random))
    when 16...30
      note_fault(coverage, "gzip reserved flag bits")
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: has_header_crc, reserved_bits: 1 + random.rand(7), modification_time: modification_time)
    when 30...44
      note_fault(coverage, "gzip header CRC")
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: true, header_crc_delta: 1 + random.rand(0xFFFF), extra_flags: extra_flags)
    when 44...58
      note_fault(coverage, "gzip CRC-32")
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: has_header_crc, crc: DeflateOracle.crc32(data) ^ (1_u32 << random.rand(32)))
    when 58...72
      note_fault(coverage, "gzip ISIZE")
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: has_header_crc, size: data.size.to_u32! ^ (1_u32 << random.rand(32)))
    when 72...82
      note_fault(coverage, "gzip short trailer")
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: has_header_crc, trailer_bytes: random.rand(8))
    when 82...90
      note_fault(coverage, "gzip unterminated name or comment")
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name || random_text(random),
        comment: comment, has_header_crc: has_header_crc, is_terminated: false)
    else
      gzip_member(raw, data, is_text: is_text, extra: extra, file_name: file_name, comment: comment,
        has_header_crc: has_header_crc, modification_time: modification_time, extra_flags: extra_flags,
        operating_system: operating_system)
    end
  end

  # One of the other families' cases, mutated one to three times.
  private def self.mutated_case(random : Random, profile : Profile, coverage : Coverage?) : Case
    base = base_case(random, profile, coverage)
    bytes = base.bytes
    (random.rand(4) == 0 ? 2 + random.rand(2) : 1).times do
      bytes = mutate(random, bytes) { base_case(random, profile, coverage, base.format).bytes }
    end
    Case.new(Family::Mutated, base.format, bytes, base.dictionary, false)
  end

  private def self.base_case(random : Random, profile : Profile, coverage : Coverage?, format : Format? = nil) : Case
    loop do
      candidate = case random.rand(3)
                  when 0 then structured_case(random, profile, coverage)
                  when 1 then compressed_case(random, profile)
                  else        container_case(random, profile, coverage)
                  end
      return candidate if format.nil? || candidate.format == format
    end
  end

  # A position biased toward the regions of a stream: the header, the
  # trailer, or anywhere.
  private def self.region_position(random : Random, size : Int32) : Int32
    return 0 if size <= 1
    case random.rand(3)
    when 0 then random.rand(Math.min(size, 24))
    when 1 then size - 1 - random.rand(Math.min(size, 12))
    else        random.rand(size)
    end
  end

  INTERESTING_BYTES = Bytes[0x00, 0xFF, 0x1F, 0x8B, 0x78, 0x08, 0x01, 0x80, 0x03, 0x9C]

  # Applies one mutation to *bytes*. The block returns another stream of
  # the same container, for splices and appended streams.
  def self.mutate(random : Random, bytes : Bytes, & : -> Bytes) : Bytes
    case random.rand(13)
    when 0, 1, 2
      mutated = bytes.dup
      (1 + random.rand(3)).times do
        next if mutated.empty?
        mutated[region_position(random, mutated.size)] ^= 1_u8 << random.rand(8)
      end
      mutated
    when 3, 4
      mutated = bytes.dup
      (1 + random.rand(4)).times do
        next if mutated.empty?
        value = random.rand(2) == 0 ? INTERESTING_BYTES.sample(random) : random.rand(256).to_u8
        mutated[region_position(random, mutated.size)] = value
      end
      mutated
    when 5, 6, 7
      bytes[0, region_position(random, bytes.size + 1)].dup
    when 8
      other = yield
      join(bytes[0, region_position(random, bytes.size + 1)], other[region_position(random, other.size + 1)..])
    when 9, 10
      tail = case random.rand(6)
             when 0 then Bytes[0x1F]
             when 1 then Bytes[0x1F, 0x8B]
             when 2 then Bytes.new(1 + random.rand(16))
             when 3 then yield
             else        random.random_bytes(1 + random.rand(16))
             end
      join(bytes, tail)
    when 11
      position = region_position(random, bytes.size + 1)
      join(bytes[0, position], random.random_bytes(1 + random.rand(4)), bytes[position..])
    else
      return bytes.dup if bytes.empty?
      position = region_position(random, bytes.size)
      count = Math.min(1 + random.rand(4), bytes.size - position)
      join(bytes[0, position], bytes[(position + count)..])
    end
  end

  def self.join(*parts : Bytes) : Bytes
    io = IO::Memory.new(parts.sum(&.size))
    parts.each { |part| io.write(part) }
    io.to_slice
  end

  # An IO over *bytes* that returns a random number of bytes per read,
  # from 1 byte to 64 KiB (always 1 when *is_trickle*).
  class ChunkedIO < IO
    def initialize(@bytes : Bytes, @random : Random, @is_trickle : Bool)
      @offset = 0
    end

    def read(slice : Bytes) : Int32
      chunk = @is_trickle ? 1 : DeflateFuzz.random_size(@random)
      count = Math.min(Math.min(chunk, slice.size), @bytes.size - @offset)
      return 0 if count <= 0
      slice[0, count].copy_from(@bytes[@offset, count])
      @offset += count
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("read-only")
    end
  end

  LARGEST_CHUNK = 65_536

  # A size from 1 byte to 64 KiB, small sizes as likely as large ones.
  def self.random_size(random : Random) : Int32
    case random.rand(8)
    when 0, 1 then 1
    when 2, 3 then 2 + random.rand(15)
    when 4, 5 then 17 + random.rand(496)
    when 6    then 513 + random.rand(3_584)
    else           4_097 + random.rand(LARGEST_CHUNK - 4_096)
    end
  end

  # Limits large enough for every generated case, so a limit error from
  # Mica is a disagreement unless the oracle's output really passes
  # `MAX_OUTPUT_BYTES`.
  MAX_OUTPUT_BYTES = 64_i64 * 1024 * 1024
  LIMITS           = Mica::Deflate::DecodeLimits.custom(max_output_bytes: MAX_OUTPUT_BYTES, max_ratio: 2_000_i64,
    max_window_bytes: WINDOW_BYTES, max_members: 1_000_000, max_metadata_bytes: 1_048_576,
    work_per_unit: 100_000_i64, base_work: 1_000_000_000_i64, work_ceiling: nil)

  # What Mica made of a case: the decoded bytes, or the error it raised
  # (with, for the Reader, the bytes it handed back before raising).
  record Outcome, output : Bytes, error : Mica::Error? do
    # A short description for reports.
    def summary : String
      error = @error
      error ? "#{error.class}: #{error.message}" : "#{@output.size} bytes"
    end
  end

  # Decodes *kase* with Mica in one call.
  def self.decode_at_once(kase : Case, limits : Mica::Deflate::DecodeLimits = LIMITS, timeout : Time::Span? = nil) : Outcome
    output = if kase.format.raw?
               Mica::Deflate.decode(kase.bytes, limits: limits, timeout: timeout)
             elsif kase.format.zlib?
               Mica::Zlib.decode(kase.bytes, limits: limits, timeout: timeout, dictionary: kase.dictionary)
             else
               Mica::Gzip.decode(kase.bytes, limits: limits, timeout: timeout)
             end
    Outcome.new(output, nil)
  rescue error : Mica::Error
    Outcome.new(Bytes.empty, error)
  end

  # Returns the streaming Reader of *kase*'s container over *io*.
  def self.reader_for(kase : Case, io : IO, limits : Mica::Deflate::DecodeLimits = LIMITS, timeout : Time::Span? = nil) : IO
    if kase.format.raw?
      Mica::Deflate::Reader.new(io, limits: limits, timeout: timeout)
    elsif kase.format.zlib?
      Mica::Zlib::Reader.new(io, limits: limits, timeout: timeout, dictionary: kase.dictionary)
    else
      Mica::Gzip::Reader.new(io, limits: limits, timeout: timeout)
    end
  end

  # Decodes *kase* through Mica's streaming Reader: the input arrives in
  # random chunks and the output is read through random slice sizes.
  def self.decode_streamed(kase : Case, random : Random, limits : Mica::Deflate::DecodeLimits = LIMITS,
                           timeout : Time::Span? = nil) : Outcome
    output = IO::Memory.new
    begin
      reader = reader_for(kase, ChunkedIO.new(kase.bytes, random, random.rand(4) == 0), limits, timeout)
      buffer = Bytes.new(LARGEST_CHUNK)
      is_single_byte_reads = random.rand(6) == 0
      loop do
        count = reader.read(buffer[0, is_single_byte_reads ? 1 : random_size(random)])
        break if count == 0
        output.write(buffer[0, count])
      end
      Outcome.new(output.to_slice, nil)
    rescue error : Mica::Error
      Outcome.new(output.to_slice, error)
    end
  end

  # How one trial ended.
  enum Verdict
    # Oracle and Mica (both ways) decoded identical bytes.
    Agreement
    # Oracle and Mica (both ways) rejected the stream.
    BothReject
    # The oracle's output passes `MAX_OUTPUT_BYTES` and Mica raised that limit.
    OverLimit
    Disagreement
  end

  # The result of one trial. *signature* names the kind of disagreement
  # without positions or sizes (the minimizer keeps it stable).
  # *list_of_streaming_differences* says how the Reader's error differs
  # from the one-shot decode's (class, input offset or message), which
  # fails the trial too. *notes* are observations that do not fail it.
  record Trial, verdict : Verdict, detail : String, signature : String, oracle : DeflateOracle::Result,
    at_once : Outcome, streamed : Outcome, list_of_streaming_differences : Array(String), notes : Array(String) do
    # Returns true when the case must be reported.
    def failed? : Bool
      @verdict.disagreement? || !@list_of_streaming_differences.empty?
    end
  end

  # Runs one case through the oracle and through Mica both ways, and
  # compares. Exceptions that are not `Mica::Error` propagate (a crash).
  def self.trial(kase : Case, random : Random) : Trial
    oracle = DeflateOracle.decode(kase.format, kase.bytes, kase.dictionary, cap: MAX_OUTPUT_BYTES + 1)
    at_once = decode_at_once(kase)
    streamed = decode_streamed(kase, random)
    problems = [] of String
    signatures = [] of String
    {"one-shot" => at_once, "Reader" => streamed}.each do |label, outcome|
      problem = compare(oracle, outcome)
      next unless problem
      problems << "#{label}: #{problem[1]}"
      signatures << "#{label} #{problem[0]}"
    end
    verdict = if !problems.empty?
                Verdict::Disagreement
              elsif oracle.accepted?
                Verdict::Agreement
              elsif oracle.rejected?
                Verdict::BothReject
              else
                Verdict::OverLimit
              end
    detail = problems.empty? ? "" : "oracle #{describe(oracle)}; #{problems.join("; ")}"
    Trial.new(verdict, detail, signatures.join(" + "), oracle, at_once, streamed, streaming_differences(at_once, streamed),
      notes_on(oracle, at_once, streamed))
  end

  private def self.describe(oracle : DeflateOracle::Result) : String
    rejection = oracle.rejection
    rejection ? "rejects (#{rejection}: #{oracle.detail}) after #{oracle.output.size} bytes" : "accepts #{oracle.output.size} bytes"
  end

  # Returns {signature, description} when *outcome* contradicts the oracle.
  private def self.compare(oracle : DeflateOracle::Result, outcome : Outcome) : {String, String}?
    error = outcome.error
    if oracle.accepted?
      return {"raised #{error.class} on a stream the oracle accepts", "raised #{outcome.summary}"} if error
      return nil if outcome.output == oracle.output
      index = (0...Math.min(outcome.output.size, oracle.output.size)).find { |at| outcome.output[at] != oracle.output[at] }
      {"decoded different bytes", "decoded #{outcome.output.size} bytes that differ from the oracle's " \
                                  "#{oracle.output.size} at byte #{index || Math.min(outcome.output.size, oracle.output.size)}"}
    elsif oracle.rejected?
      return {"accepted a stream the oracle rejects", "accepted #{outcome.output.size} bytes"} unless error
      return nil if error.is_a?(Mica::Deflate::MalformedStreamError)
      {"raised #{error.class} on a stream the oracle rejects as malformed", "raised #{outcome.summary}"}
    else
      return {"accepted output past the limit", "accepted #{outcome.output.size} bytes"} unless error
      return nil if error.is_a?(Mica::Deflate::DecodeLimitError) && error.limit == "max_output_bytes"
      {"raised #{error.class} where max_output_bytes is passed", "raised #{outcome.summary}"}
    end
  end

  # How the Reader's error differs from the one-shot decode's. Both paths
  # must raise the same error at the same input offset, however the input
  # is chunked.
  private def self.streaming_differences(at_once : Outcome, streamed : Outcome) : Array(String)
    list_of_differences = [] of String
    first = at_once.error
    second = streamed.error
    return list_of_differences unless first && second
    if first.class != second.class
      list_of_differences << "one-shot and Reader error classes differ"
    elsif first.is_a?(Mica::ParseError) && second.is_a?(Mica::ParseError)
      list_of_differences << "one-shot and Reader error offsets differ" if first.byte_offset != second.byte_offset
      list_of_differences << "one-shot and Reader error messages differ" if first.detail != second.detail
    end
    list_of_differences
  end

  # Observations that do not fail a trial but that the campaign counts: a
  # truncation the oracle sees that Mica names differently (or the other
  # way around), and Reader output before an error that is not what the
  # oracle produced.
  private def self.notes_on(oracle : DeflateOracle::Result, at_once : Outcome, streamed : Outcome) : Array(String)
    notes = [] of String
    first = at_once.error
    second = streamed.error
    if first && oracle.rejected?
      is_truncated = oracle.rejection == DeflateOracle::Rejection::Truncated
      if is_truncated != first.is_a?(Mica::Deflate::TruncatedStreamError)
        notes << (is_truncated ? "oracle sees truncation, Mica another error" : "Mica sees truncation, oracle another error")
      end
    end
    if second && oracle.rejected? && !starts_with?(oracle.output, streamed.output)
      notes << "Reader output before the error is not a prefix of the oracle's"
    end
    notes
  end

  private def self.starts_with?(whole : Bytes, prefix : Bytes) : Bool
    prefix.size <= whole.size && whole[0, prefix.size] == prefix
  end

  # Counts of one family or container.
  class Tally
    getter cases = 0
    getter agreements = 0
    getter both_reject = 0
    getter over_limit = 0
    getter disagreements = 0

    # :nodoc:
    def record(verdict : Verdict?) : Nil
      @cases += 1
      case verdict
      when Verdict::Agreement  then @agreements += 1
      when Verdict::BothReject then @both_reject += 1
      when Verdict::OverLimit  then @over_limit += 1
      else                          @disagreements += 1
      end
    end

    def to_s(io : IO) : Nil
      io << @cases << '/' << @agreements << '/' << @both_reject << '/' << @disagreements
    end
  end

  # Counts for a finished run. Lists hold replayable ids (SEED:ITERATION)
  # with a short reason.
  class Report
    getter total = Tally.new
    getter by_family = Hash(Family, Tally).new { |hash, family| hash[family] = Tally.new }
    getter by_format = Hash(Format, Tally).new { |hash, format| hash[format] = Tally.new }
    getter list_of_disagreements = [] of String
    getter list_of_crashes = [] of String
    # Cases whose Reader error differs from the one-shot error.
    getter list_of_streaming_differences = [] of String
    getter streaming_differences = Hash(String, Int32).new(0)
    # Cases a generator meant to be valid that the oracle rejected (a
    # generator defect, not a decoder one).
    getter list_of_rejected_valid_cases = [] of String
    getter notes = Hash(String, Int32).new(0)
    getter list_of_note_examples = [] of String
    getter mica_errors = Hash(String, Int32).new(0)
    getter oracle_rejections = Hash(String, Int32).new(0)
    getter coverage = Coverage.new
    getter input_bytes = 0_i64
    getter output_bytes = 0_i64

    # :nodoc:
    def record(id : String, kase : Case, trial : Trial?) : Nil
      verdict = trial ? trial.verdict : nil
      @total.record(verdict)
      @by_family[kase.family].record(verdict)
      @by_format[kase.format].record(verdict)
      @input_bytes += kase.bytes.size
      return unless trial
      @output_bytes += trial.oracle.output.size
      if rejection = trial.oracle.rejection
        @oracle_rejections[rejection.to_s] += 1
        @list_of_rejected_valid_cases << "#{id} #{kase.family} #{kase.format}: #{trial.oracle.detail}" if kase.is_meant_to_be_valid
      end
      if error = trial.at_once.error
        @mica_errors[error.class.name] += 1
      end
      trial.notes.each do |note|
        @notes[note] += 1
        @list_of_note_examples << "#{id} #{note}" if @notes[note] <= 3
      end
      unless trial.list_of_streaming_differences.empty?
        trial.list_of_streaming_differences.each { |difference| @streaming_differences[difference] += 1 }
        @list_of_streaming_differences << "#{id} #{kase.family} #{kase.format} #{kase.bytes.size} bytes: " \
                                          "one-shot #{trial.at_once.summary}; Reader #{trial.streamed.summary}"
      end
      return unless trial.verdict.disagreement?
      @list_of_disagreements << "#{id} #{kase.family} #{kase.format} #{kase.bytes.size} bytes: #{trial.detail}"
    end

    # Returns true when nothing disagreed, crashed, or was wrongly generated.
    def clean? : Bool
      @list_of_disagreements.empty? && @list_of_crashes.empty? && @list_of_rejected_valid_cases.empty? &&
        @list_of_streaming_differences.empty?
    end

    def to_s(io : IO) : Nil
      io << "cases=" << @total.cases << " agreements=" << @total.agreements << " both_reject=" << @total.both_reject
      io << " over_limit=" << @total.over_limit << " disagreements=" << @list_of_disagreements.size
      io << " streaming_differences=" << @list_of_streaming_differences.size
      io << " crashes=" << @list_of_crashes.size << " rejected_valid=" << @list_of_rejected_valid_cases.size
      Family.each { |family| io << ' ' << family.to_s.downcase << '=' << @by_family[family] }
      Format.each { |format| io << ' ' << format.to_s.downcase << '=' << @by_format[format] }
      io << " input_bytes=" << @input_bytes << " output_bytes=" << @output_bytes
    end
  end

  # Runs cases *first* to `first + count - 1` of the run *seed* and
  # returns the report. The block, when given, receives every failing
  # case (a disagreement or a crash) with its id.
  def self.run(seed : Int64, count : Int32, first : Int32 = 0, profile : Profile = Profile::FULL,
               & : String, Case, Trial? ->) : Report
    report = Report.new
    count.times do |offset|
      iteration = first + offset
      id = "#{seed}:#{iteration}"
      kase = case_for(seed, iteration, profile, report.coverage)
      trial = begin
        trial(kase, random_for(seed, iteration, 1))
      rescue error : Exception
        report.list_of_crashes << "#{id} #{kase.family} #{kase.format} #{kase.bytes.size} bytes: #{error.class}: #{error.message}"
        nil
      end
      report.record(id, kase, trial)
      yield id, kase, trial if trial.nil? || trial.failed?
    end
    report
  end

  # :ditto:
  def self.run(seed : Int64, count : Int32, first : Int32 = 0, profile : Profile = Profile::FULL) : Report
    run(seed, count, first, profile) { }
  end

  # What a case does wrong, as a stable string: the disagreement's
  # signature, the first streaming difference, the first note, or the
  # crash's exception class. Nil when there is nothing to say.
  # *origin* is the case's {seed, iteration}: with it the Reader sees the
  # chunk sizes of the campaign's trial, which a streaming difference may
  # depend on.
  def self.failure_signature(kase : Case, origin : {Int64, Int32}? = nil) : String?
    result = trial(kase, origin ? random_for(origin[0], origin[1], 1) : Random::PCG32.new(1_u64, 1_u64))
    return result.signature if result.verdict.disagreement?
    result.list_of_streaming_differences.first? || result.notes.first?
  rescue error : Exception
    "crash #{error.class}"
  end

  # Returns the smallest input found (by removing ever smaller pieces,
  # then zeroing bytes) that fails the same way as *kase*.
  def self.minimize(kase : Case, origin : {Int64, Int32}? = nil) : Case
    signature = failure_signature(kase, origin)
    return kase unless signature
    bytes = kase.bytes
    piece = Math.max(bytes.size // 2, 1)
    while piece >= 1
      offset = 0
      while offset < bytes.size
        candidate = join(bytes[0, offset], bytes[Math.min(offset + piece, bytes.size)..])
        if failure_signature(kase.copy_with(bytes: candidate), origin) == signature
          bytes = candidate
        else
          offset += piece
        end
      end
      break if piece == 1
      piece //= 2
    end
    if bytes.size <= 4_096
      bytes.size.times do |index|
        next if bytes[index] == 0
        candidate = bytes.dup
        candidate[index] = 0_u8
        bytes = candidate if failure_signature(kase.copy_with(bytes: candidate), origin) == signature
      end
    end
    kase.copy_with(bytes: bytes)
  end
end
