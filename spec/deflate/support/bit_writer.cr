require "../../spec_helper"

# Support for the Mica::Deflate conformance specs (spec/deflate/): a
# bit-level writer and block builders that produce DEFLATE (RFC 1951), zlib
# (RFC 1950) and gzip (RFC 1952) streams by hand, including invalid ones;
# reference checksums written from the RFC formulas; and the vector
# registry that lets streaming_spec.cr replay every vector the other spec
# files declare.
module DeflateConformance
  # RFC 1951 3.2.5: the base length of length symbols 257..285.
  LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  # RFC 1951 3.2.5: the extra bits of length symbols 257..285.
  LENGTH_EXTRA_BITS = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  # RFC 1951 3.2.5: the base distance of distance symbols 0..29.
  DISTANCE_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
  # RFC 1951 3.2.5: the extra bits of distance symbols 0..29.
  DISTANCE_EXTRA_BITS = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  # RFC 1951 3.2.7: the order in which code length code lengths are sent.
  CODE_LENGTH_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
  # RFC 1951 3.2.6: the code lengths of the fixed literal/length code.
  FIXED_LITERAL_LENGTHS = Array.new(288) do |symbol|
    if symbol < 144
      8
    elsif symbol < 256
      9
    elsif symbol < 280
      7
    else
      8
    end
  end
  # RFC 1951 3.2.6: the fixed distance code is 32 codes of 5 bits.
  FIXED_DISTANCE_LENGTHS = Array.new(32, 5)
  # A complete code length code that gives every one of the 19 symbols a
  # code (13 codes of 4 bits and 6 of 5 bits), for dynamic headers that do
  # not care about the code length code itself.
  PLAIN_CODE_LENGTH_CODE_LENGTHS = Array.new(19) { |symbol| symbol < 13 ? 4 : 5 }

  # The limits the conformance vectors decode under: the full 32 KiB
  # window and room for every vector, so only the stream's validity
  # decides the outcome.
  LIMITS = Mica::Deflate::DecodeLimits.custom(
    max_output_bytes: 64_i64 * 1024 * 1024,
    max_ratio: 100_000_i64,
    max_window_bytes: 32_768,
    max_members: 1_000,
    max_metadata_bytes: 1_048_576,
  )

  # Writes bits in DEFLATE order (RFC 1951 3.1.1): each byte fills from its
  # least significant bit.
  class BitWriter
    # The number of bits written so far.
    getter bit_count : Int64 = 0_i64

    def initialize
      @io = IO::Memory.new
      @current = 0_u8
      @used = 0
    end

    # Appends the low *count* bits of *value*, least significant bit first,
    # as RFC 1951 packs every data element except Huffman codes.
    def bits(value : Int, count : Int32) : self
      count.times { |index| push((value >> index) & 1) }
      self
    end

    # Appends a Huffman code of *length* bits, most significant bit first.
    def huffman(code : Int, length : Int32) : self
      (length - 1).downto(0) { |index| push((code >> index) & 1) }
      self
    end

    # Pads to the next byte boundary with copies of the bit *fill*.
    def align(fill : Int32 = 0) : self
      while @used != 0
        push(fill)
      end
      self
    end

    # Appends whole bytes; the writer must be on a byte boundary.
    def bytes(data : Bytes) : self
      raise ArgumentError.new("BitWriter#bytes needs a byte boundary") unless @used == 0
      @io.write(data)
      @bit_count += data.size.to_i64 * 8
      self
    end

    # Returns the bytes written, the last one padded with zero bits.
    def to_slice : Bytes
      io = IO::Memory.new
      io.write(@io.to_slice)
      io.write_byte(@current) if @used > 0
      io.to_slice
    end

    private def push(bit : Int) : Nil
      @current |= 1_u8 << @used if bit != 0
      @used += 1
      @bit_count += 1
      if @used == 8
        @io.write_byte(@current)
        @current = 0_u8
        @used = 0
      end
    end
  end

  # One Huffman code: its *length* low bits of *bits*, sent most significant
  # bit first.
  record HuffmanCode, bits : Int32, length : Int32

  # Assigns canonical codes to *list_of_lengths* with the algorithm of
  # RFC 1951 3.2.2. A symbol of length 0 gets nil. Lengths that do not form
  # a prefix code (oversubscribed sets) still get the bits the algorithm
  # yields, so a spec can write them.
  def self.canonical_codes(list_of_lengths : Array(Int32)) : Array(HuffmanCode?)
    count_by_length = Array.new(17, 0)
    list_of_lengths.each { |length| count_by_length[length] += 1 if length > 0 }
    next_code = Array.new(17, 0)
    code = 0
    1.upto(16) do |length|
      code = (code + count_by_length[length - 1]) << 1
      next_code[length] = code
    end
    list_of_lengths.map do |length|
      next nil if length == 0
      assigned = next_code[length]
      next_code[length] += 1
      HuffmanCode.new(assigned, length)
    end
  end

  # Writes the code length sequence of a dynamic block header
  # (RFC 1951 3.2.7) with a given code length code.
  class CodeLengthWriter
    def initialize(@bit_writer : BitWriter, @list_of_codes : Array(HuffmanCode?))
    end

    # Writes code length symbol *symbol* (0..18) followed by *extra* in the
    # symbol's extra bits (2 for 16, 3 for 17, 7 for 18).
    def symbol(symbol : Int32, extra : Int32 = 0) : self
      code = @list_of_codes[symbol]? || raise ArgumentError.new("Code length symbol #{symbol} has no code")
      @bit_writer.huffman(code.bits, code.length)
      if symbol == 16
        @bit_writer.bits(extra, 2)
      elsif symbol == 17
        @bit_writer.bits(extra, 3)
      elsif symbol == 18
        @bit_writer.bits(extra, 7)
      end
      self
    end

    # Writes one literal code length (0..15).
    def length(value : Int32) : self
      symbol(value)
    end

    # Writes each of *list_of_lengths* as a literal code length.
    def lengths(list_of_lengths : Array(Int32)) : self
      list_of_lengths.each { |value| symbol(value) }
      self
    end

    # Writes symbol 16: repeat the previous length *times* (3..6) times.
    def repeat_previous(times : Int32) : self
      symbol(16, times - 3)
    end

    # Writes symbol 17 (3..10 zeros) or symbol 18 (11..138 zeros).
    def zeros(times : Int32) : self
      times <= 10 ? symbol(17, times - 3) : symbol(18, times - 11)
    end
  end

  # Writes the symbols of one compressed block with given literal/length
  # and distance codes, and tells the stream what a decoder must output.
  class BlockWriter
    def initialize(@stream : DeflateWriter, @list_of_literal_codes : Array(HuffmanCode?), @list_of_distance_codes : Array(HuffmanCode?))
    end

    # Writes the literal *byte*.
    def literal(byte : Int) : self
      symbol(byte.to_i32)
      @stream.record_literal(byte.to_u8)
      self
    end

    # Writes each byte of *data* as a literal.
    def literals(data : Bytes | String) : self
      data.to_slice.each { |byte| literal(byte) }
      self
    end

    # Writes the back reference (*length*, *distance*) with the symbols and
    # extra bits RFC 1951 3.2.5 assigns (length 258 as symbol 285).
    def match(length : Int32, distance : Int32) : self
      length_index = LENGTH_BASE.rindex! { |base| base <= length }
      distance_index = DISTANCE_BASE.rindex! { |base| base <= distance }
      match_symbols(257 + length_index, length - LENGTH_BASE[length_index], distance_index, distance - DISTANCE_BASE[distance_index])
    end

    # Writes a back reference from explicit symbols and extra bit values.
    def match_symbols(length_symbol : Int32, length_extra : Int32, distance_symbol : Int32, distance_extra : Int32) : self
      length(length_symbol, length_extra)
      distance(distance_symbol, distance_extra)
      # Symbol 284 with extra bits 31 would be 259; zlib decodes it as 258.
      copied = Math.min(LENGTH_BASE[length_symbol - 257] + length_extra, 258)
      @stream.record_copy(copied, DISTANCE_BASE[distance_symbol] + distance_extra)
      self
    end

    # Writes literal/length symbol *symbol* alone (any symbol with a code).
    def symbol(symbol : Int32) : self
      code = @list_of_literal_codes[symbol]? || raise ArgumentError.new("Literal/length symbol #{symbol} has no code")
      @stream.bit_writer.huffman(code.bits, code.length)
      self
    end

    # Writes length symbol *symbol* and *extra* in its extra bits.
    def length(symbol : Int32, extra : Int32 = 0) : self
      symbol(symbol)
      @stream.bit_writer.bits(extra, LENGTH_EXTRA_BITS[symbol - 257]) if symbol <= 285
      self
    end

    # Writes distance symbol *symbol* and *extra* in its extra bits.
    def distance(symbol : Int32, extra : Int32 = 0) : self
      code = @list_of_distance_codes[symbol]? || raise ArgumentError.new("Distance symbol #{symbol} has no code")
      @stream.bit_writer.huffman(code.bits, code.length)
      @stream.bit_writer.bits(extra, DISTANCE_EXTRA_BITS[symbol]) if symbol <= 29
      self
    end

    # Writes the end-of-block symbol (256).
    def end_of_block : self
      symbol(256)
    end
  end

  # Builds a raw DEFLATE stream block by block and tracks the bytes a
  # decoder must produce for the valid parts (`expected`).
  class DeflateWriter
    getter bit_writer : BitWriter = BitWriter.new

    # *dictionary* is a preset dictionary (RFC 1950 2.2): history that back
    # references may reach but that is not part of the output.
    def initialize(dictionary : Bytes? = nil)
      @history = [] of UInt8
      dictionary.each { |byte| @history << byte } if dictionary
      @dictionary_size = @history.size
    end

    # Writes a block header: BFINAL, then the 2-bit BTYPE.
    def block_header(type : Int32, final : Bool) : self
      @bit_writer.bits(final ? 1 : 0, 1).bits(type, 2)
      self
    end

    # Writes a stored block (RFC 1951 3.2.4). *padding_bit* fills the bits
    # up to the byte boundary; *declared_length* and *declared_complement*
    # replace LEN and NLEN.
    def stored(data : Bytes, final : Bool = false, padding_bit : Int32 = 0, declared_length : Int32? = nil, declared_complement : Int32? = nil) : self
      block_header(0, final)
      @bit_writer.align(padding_bit)
      length = declared_length || data.size
      @bit_writer.bits(length, 16).bits(declared_complement || (length ^ 0xFFFF), 16).bytes(data)
      data.each { |byte| @history << byte }
      self
    end

    # Writes a block compressed with the fixed codes (RFC 1951 3.2.6).
    def fixed(final : Bool = false, end_of_block : Bool = true, & : BlockWriter ->) : self
      block_header(1, final)
      symbols(FIXED_LITERAL_LENGTHS, FIXED_DISTANCE_LENGTHS, end_of_block) { |block| yield block }
    end

    # Writes a dynamic block (RFC 1951 3.2.7) whose header lists every code
    # length literally under `PLAIN_CODE_LENGTH_CODE_LENGTHS`.
    def dynamic(list_of_literal_lengths : Array(Int32), list_of_distance_lengths : Array(Int32), final : Bool = false, end_of_block : Bool = true, & : BlockWriter ->) : self
      dynamic_header(list_of_literal_lengths.size, list_of_distance_lengths.size, final: final) do |code_lengths|
        code_lengths.lengths(list_of_literal_lengths).lengths(list_of_distance_lengths)
      end
      symbols(list_of_literal_lengths, list_of_distance_lengths, end_of_block) { |block| yield block }
    end

    # Writes a dynamic block header: HLIT (*literal_count* - 257), HDIST
    # (*distance_count* - 1), HCLEN (*code_length_count* - 4), the first
    # *code_length_count* code length code lengths in transmission order,
    # then whatever the block writes as the code length sequence.
    def dynamic_header(literal_count : Int32, distance_count : Int32, final : Bool = false, list_of_code_length_code_lengths : Array(Int32) = PLAIN_CODE_LENGTH_CODE_LENGTHS, code_length_count : Int32 = 19, & : CodeLengthWriter ->) : self
      block_header(2, final)
      @bit_writer.bits(literal_count - 257, 5).bits(distance_count - 1, 5).bits(code_length_count - 4, 4)
      code_length_count.times { |index| @bit_writer.bits(list_of_code_length_code_lengths[CODE_LENGTH_ORDER[index]], 3) }
      yield CodeLengthWriter.new(@bit_writer, DeflateConformance.canonical_codes(list_of_code_length_code_lengths))
      self
    end

    # Writes block symbols under the canonical codes of the given lengths.
    def symbols(list_of_literal_lengths : Array(Int32), list_of_distance_lengths : Array(Int32), end_of_block : Bool = true, & : BlockWriter ->) : self
      block = BlockWriter.new(self, DeflateConformance.canonical_codes(list_of_literal_lengths), DeflateConformance.canonical_codes(list_of_distance_lengths))
      yield block
      block.end_of_block if end_of_block
      self
    end

    # :nodoc:
    def record_literal(byte : UInt8) : Nil
      @history << byte
    end

    # :nodoc:
    def record_copy(length : Int32, distance : Int32) : Nil
      # A reference before the start of the history is invalid; the vector
      # that writes one expects a rejection, not output.
      return if distance > @history.size
      length.times { @history << @history[@history.size - distance] }
    end

    # Returns the bytes a decoder must produce for the stream so far.
    def expected : Bytes
      Bytes.new(@history.size - @dictionary_size) { |index| @history[@dictionary_size + index] }
    end

    # Returns the stream, its last byte padded with zero bits.
    def to_slice : Bytes
      @bit_writer.to_slice
    end
  end

  # Builds a raw DEFLATE stream.
  def self.deflate(dictionary : Bytes? = nil, & : DeflateWriter ->) : DeflateWriter
    stream = DeflateWriter.new(dictionary)
    yield stream
    stream
  end

  # Decodes hexadecimal bytes separated by white space; a single digit is a
  # whole byte, as in zlib's infcover.c ("63 0" is 0x63 0x00).
  def self.hex(text : String) : Bytes
    list_of_tokens = text.split
    Bytes.new(list_of_tokens.size) { |index| list_of_tokens[index].to_u8(16) }
  end

  # Returns *data* as lower-case hexadecimal, clipped for failure messages.
  def self.hex_of(data : Bytes, limit : Int32 = 96) : String
    shown = data.size > limit ? data[0, limit] : data
    text = shown.join(' ') { |byte| byte.to_s(16).rjust(2, '0') }
    data.size > limit ? "#{text} ... (#{data.size} bytes)" : text
  end

  # Returns *size* bytes of fixed pseudo-random data (a linear congruential
  # generator), so vectors are the same on every run.
  def self.sample_bytes(size : Int32, seed : UInt32 = 1_u32) : Bytes
    state = seed
    Bytes.new(size) do
      state = state &* 1_103_515_245_u32 &+ 12_345_u32
      (state >> 16).to_u8!
    end
  end

  # The CRC-32 of RFC 1952 section 8, computed bit by bit from the
  # polynomial 0xEDB88320 (no table), as an independent reference.
  def self.reference_crc32(data : Bytes) : UInt32
    crc = 0xFFFF_FFFF_u32
    data.each do |byte|
      crc ^= byte
      8.times { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320_u32 : crc >> 1 }
    end
    crc ^ 0xFFFF_FFFF_u32
  end

  # The Adler-32 of RFC 1950 section 8.2, reducing modulo 65521 at every
  # byte, as an independent reference.
  def self.reference_adler32(data : Bytes) : UInt32
    low = 1_u32
    high = 0_u32
    data.each do |byte|
      low = (low + byte) % 65_521_u32
      high = (high + low) % 65_521_u32
    end
    (high << 16) | low
  end

  # Wraps raw DEFLATE data in a zlib stream (RFC 1950). *data* is the
  # uncompressed data the Adler-32 trailer covers. *check_adjustment* is
  # added to the valid FCHECK; *adler* and *dictionary_id* replace the
  # computed values.
  def self.zlib_stream(deflated : Bytes, data : Bytes, compression_info : Int32 = 7, level : Int32 = 2, method : Int32 = 8, dictionary : Bytes? = nil, dictionary_id : UInt32? = nil, check_adjustment : Int32 = 0, adler : UInt32? = nil) : Bytes
    io = IO::Memory.new
    cmf = (compression_info << 4) | method
    flg = (level << 6) | (dictionary || dictionary_id ? 0x20 : 0)
    flg += (31 - (cmf * 256 + flg) % 31) % 31
    io.write_byte(cmf.to_u8)
    io.write_byte((flg + check_adjustment).to_u8)
    if dictionary || dictionary_id
      io.write_bytes(dictionary_id || reference_adler32(dictionary || Bytes.empty), IO::ByteFormat::BigEndian)
    end
    io.write(deflated)
    io.write_bytes(adler || reference_adler32(data), IO::ByteFormat::BigEndian)
    io.to_slice
  end

  # Builds one gzip member (RFC 1952 2.3). *data* is the uncompressed data
  # the CRC-32 and ISIZE trailer covers. A non-nil *extra*, *file_name* or
  # *comment* sets FEXTRA, FNAME or FCOMMENT (the terminating zero is
  # added); *header_crc* sets FHCRC. *crc*, *size*, *header_crc_value* and
  # *declared_extra_size* replace the computed values, and *flags* replaces
  # the whole FLG byte.
  def self.gzip_member(
    deflated : Bytes, data : Bytes, text : Bool = false, header_crc : Bool = false, extra : Bytes? = nil,
    file_name : Bytes? = nil, comment : Bytes? = nil, modification_time : UInt32 = 0_u32,
    extra_flags : UInt8 = 0_u8, operating_system : UInt8 = 255_u8, method : UInt8 = 8_u8,
    first_magic : UInt8 = 0x1f_u8, second_magic : UInt8 = 0x8b_u8, reserved_flags : Int32 = 0,
    flags : UInt8? = nil, crc : UInt32? = nil, size : UInt32? = nil, header_crc_value : UInt16? = nil,
    declared_extra_size : Int32? = nil,
  ) : Bytes
    io = IO::Memory.new
    io.write_byte(first_magic)
    io.write_byte(second_magic)
    io.write_byte(method)
    computed_flags = reserved_flags
    computed_flags |= 0x01 if text
    computed_flags |= 0x02 if header_crc
    computed_flags |= 0x04 if extra
    computed_flags |= 0x08 if file_name
    computed_flags |= 0x10 if comment
    io.write_byte(flags || computed_flags.to_u8)
    io.write_bytes(modification_time, IO::ByteFormat::LittleEndian)
    io.write_byte(extra_flags)
    io.write_byte(operating_system)
    if extra
      io.write_bytes((declared_extra_size || extra.size).to_u16, IO::ByteFormat::LittleEndian)
      io.write(extra)
    end
    if file_name
      io.write(file_name)
      io.write_byte(0_u8)
    end
    if comment
      io.write(comment)
      io.write_byte(0_u8)
    end
    if header_crc
      io.write_bytes(header_crc_value || (reference_crc32(io.to_slice) & 0xFFFF).to_u16, IO::ByteFormat::LittleEndian)
    end
    io.write(deflated)
    io.write_bytes(crc || reference_crc32(data), IO::ByteFormat::LittleEndian)
    io.write_bytes(size || data.size.to_u32!, IO::ByteFormat::LittleEndian)
    io.to_slice
  end

  # Joins byte strings.
  def self.join(*list_of_parts : Bytes) : Bytes
    join(list_of_parts)
  end

  # :ditto:
  def self.join(list_of_parts : Enumerable(Bytes)) : Bytes
    io = IO::Memory.new
    list_of_parts.each { |part| io.write(part) }
    io.to_slice
  end

  # The container a vector is in.
  enum Format
    Raw
    Zlib
    Gzip
  end

  # How a decoder must refuse an invalid vector: `Malformed` is exactly
  # `MalformedStreamError`, `Truncated` is `TruncatedStreamError` and
  # `Checksum` is `ChecksumError`.
  enum Rejection
    Malformed
    Truncated
    Checksum
  end

  # One conformance vector: a stream and the output or rejection required.
  record Vector, label : String, format : Format, input : Bytes, expected : Bytes | Rejection, dictionary : Bytes?

  # What a decode did: its output, or the kind of error and where.
  record Outcome, output : Bytes?, rejection : String?, byte_offset : Int64? do
    def to_s(io : IO) : Nil
      if decoded = output
        io << "output of " << decoded.size << " bytes (" << DeflateConformance.hex_of(decoded, 32) << ")"
      else
        io << rejection << " at byte " << byte_offset
      end
    end
  end

  # Every vector declared with `it_decodes_vector` or `it_rejects_vector`,
  # in declaration order.
  LIST_OF_VECTORS = [] of Vector

  # The chunk sizes the streaming specs trickle input at.
  LIST_OF_CHUNK_SIZES = [1, 2, 3, 7, 4096]

  # Runs a decode and reports what it did. Only stream errors are an
  # outcome; a limit error or any other exception fails the example.
  def self.outcome_of(& : -> Bytes) : Outcome
    Outcome.new(yield, nil, nil)
  rescue error : Mica::Deflate::MalformedStreamError
    kind = if error.is_a?(Mica::Deflate::TruncatedStreamError)
             "Truncated"
           elsif error.is_a?(Mica::Deflate::ChecksumError)
             "Checksum"
           elsif error.class == Mica::Deflate::MalformedStreamError
             "Malformed"
           else
             error.class.name
           end
    Outcome.new(nil, kind, error.byte_offset)
  end

  # Decodes *vector* with the one-shot API.
  def self.decode_one_shot(vector : Vector) : Outcome
    outcome_of { decode(vector.format, vector.input, vector.dictionary) }
  end

  # Decodes *input* in *format* with the one-shot API.
  def self.decode(format : Format, input : Bytes, dictionary : Bytes? = nil) : Bytes
    if format.raw?
      Mica::Deflate.decode(input, limits: LIMITS, timeout: nil)
    elsif format.zlib?
      Mica::Zlib.decode(input, limits: LIMITS, timeout: nil, dictionary: dictionary)
    else
      Mica::Gzip.decode(input, limits: LIMITS, timeout: nil)
    end
  end

  # Returns the streaming reader for *format* over *io*.
  def self.reader(format : Format, io : IO, dictionary : Bytes? = nil) : IO
    if format.raw?
      Mica::Deflate::Reader.new(io, limits: LIMITS, timeout: nil)
    elsif format.zlib?
      Mica::Zlib::Reader.new(io, limits: LIMITS, timeout: nil, dictionary: dictionary)
    else
      Mica::Gzip::Reader.new(io, limits: LIMITS, timeout: nil)
    end
  end

  # Decodes *vector* through the Reader, feeding it *chunk_size* input
  # bytes per read and asking for *read_size* output bytes per read.
  def self.decode_streaming(vector : Vector, chunk_size : Int32, read_size : Int32) : Outcome
    outcome_of do
      reader = reader(vector.format, TrickleIO.new(vector.input, chunk_size), vector.dictionary)
      output = IO::Memory.new
      buffer = Bytes.new(read_size)
      loop do
        count = reader.read(buffer)
        break if count == 0
        output.write(buffer[0, count])
      end
      output.to_slice
    end
  end

  # Fails unless *outcome* is what *vector* requires.
  def self.check(vector : Vector, outcome : Outcome, how : String) : Nil
    expected = vector.expected
    matches = if expected.is_a?(Bytes)
                outcome.output == expected
              else
                outcome.rejection == expected.to_s
              end
    return if matches
    wanted = expected.is_a?(Bytes) ? "output of #{expected.size} bytes (#{hex_of(expected, 32)})" : expected.to_s
    fail "#{vector.format} vector #{vector.label.inspect} (#{how}): expected #{wanted}, got #{outcome}; input: #{hex_of(vector.input)}"
  end

  # Fails unless every proper prefix of *input* is refused as truncated,
  # except the prefix sizes in *list_of_complete_sizes* (the ends of
  # earlier gzip members), which must decode.
  def self.check_every_prefix_is_truncated(format : Format, input : Bytes, dictionary : Bytes? = nil, list_of_complete_sizes : Array(Int32) = [] of Int32) : Nil
    input.size.times do |size|
      outcome = outcome_of { decode(format, input[0, size], dictionary) }
      if list_of_complete_sizes.includes?(size)
        fail "prefix of #{size} bytes: expected output, got #{outcome}; input: #{hex_of(input)}" unless outcome.output
      elsif outcome.rejection != "Truncated"
        fail "prefix of #{size} of #{input.size} bytes: expected Truncated, got #{outcome}; input: #{hex_of(input)}"
      end
    end
  end
end

# Defines an example that requires *input* to decode to *expected*, and
# registers the vector for the streaming specs.
def it_decodes_vector(requirement_id : String | Tuple, description : String, format : DeflateConformance::Format, input : Bytes, expected : Bytes, dictionary : Bytes? = nil, file = __FILE__, line = __LINE__, end_line = __END_LINE__) : Nil
  vector = DeflateConformance::Vector.new(description, format, input, expected, dictionary)
  DeflateConformance::LIST_OF_VECTORS << vector
  it_satisfies(requirement_id, description, file, line, end_line) do
    DeflateConformance.check(vector, DeflateConformance.decode_one_shot(vector), "one-shot")
  end
end

# Defines an example that requires *input* to be refused as *rejection*,
# and registers the vector for the streaming specs.
def it_rejects_vector(requirement_id : String | Tuple, description : String, format : DeflateConformance::Format, input : Bytes, rejection : DeflateConformance::Rejection, dictionary : Bytes? = nil, file = __FILE__, line = __LINE__, end_line = __END_LINE__) : Nil
  vector = DeflateConformance::Vector.new(description, format, input, rejection, dictionary)
  DeflateConformance::LIST_OF_VECTORS << vector
  it_satisfies(requirement_id, description, file, line, end_line) do
    DeflateConformance.check(vector, DeflateConformance.decode_one_shot(vector), "one-shot")
  end
end

# Defines an example for the raw DEFLATE stream the block builds, which
# must decode to the output the builder tracked.
def it_inflates(requirement_id : String | Tuple, description : String, file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block : DeflateConformance::DeflateWriter ->) : Nil
  stream = DeflateConformance.deflate { |deflate| block.call(deflate) }
  it_decodes_vector(requirement_id, description, :raw, stream.to_slice, stream.expected, nil, file, line, end_line)
end

# Defines an example for the raw DEFLATE stream the block builds, which
# must be refused as *rejection*.
def it_refuses_to_inflate(requirement_id : String | Tuple, description : String, rejection : DeflateConformance::Rejection, file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block : DeflateConformance::DeflateWriter ->) : Nil
  stream = DeflateConformance.deflate { |deflate| block.call(deflate) }
  it_rejects_vector(requirement_id, description, :raw, stream.to_slice, rejection, nil, file, line, end_line)
end
