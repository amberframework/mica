require "../spec_helper"

# A toy binary format built only on Mica::Core, to prove a binary format
# plugs into the shared input, limits, work budget and error types with no
# core changes (docs/ADDING_A_FORMAT.md walks through it).
#
# Grammar: a sequence of records, each `tag:u8 length:u8 payload[length]`.
# A tag of 0 is reserved and rejected.
class ToyRecordReader
  include Mica::Core::ByteInput

  record Item, tag : UInt8, payload : Bytes, offset : Int64

  getter meter : Mica::Core::WorkMeter

  def initialize(source : Bytes | IO, @token_limit : Int32 = 255, @size_limit : Int64? = nil,
                 budget : Mica::Core::WorkBudget = Mica::Core::WorkBudget.new)
    @meter = Mica::Core::WorkMeter.new(budget)
    if source.is_a?(Bytes)
      setup_in_memory(source)
    else
      setup_stream(source)
    end
  end

  # Returns the next record, or nil at the end of the input.
  def next_item : Item?
    @mark = @pos
    return if at_source_end?
    tag = peek_byte.to_u8
    error("Reserved tag 0") if tag == 0
    error("Truncated record header") unless ensure_bytes(2)
    length = @buffer[@pos + 1].to_i32
    error("Truncated record payload") unless ensure_bytes(2 + length)
    payload = @buffer[@pos + 2, length].dup
    offset = source_offset_at(@buffer, @pos, @base_offset)
    @pos += 2 + length
    charge(2 + length)
    Item.new(tag, payload, offset)
  end

  private def charge(count : Int32) : Nil
    @meter.enforce { here } if @meter.charge(count)
  end

  private def here : Mica::Core::Position
    Mica::Core::Position.new(source_offset_at(@buffer, @pos, @base_offset))
  end

  private def error(message : String) : NoReturn
    raise Mica::ParseError.new(message, here)
  end

  private def input_token_limit : Int32
    @token_limit
  end

  private def input_size_limit : Int64?
    @size_limit
  end

  private def input_limit_error(message : String) : NoReturn
    raise Mica::LimitExceededError.new(message, here)
  end

  private def discarding_input(keep : Int32) : Nil
  end

  # New bytes raise the allowance; a read is where the reader may have
  # waited, so the deadline is checked here.
  private def input_received(count : Int32) : Nil
    @meter.add_units(count)
    @meter.enforce_deadline { here }
  end
end

private def toy_records(count : Int32) : Bytes
  io = IO::Memory.new
  count.times do |index|
    payload_size = index % 200
    io.write_byte((1 + index % 250).to_u8)
    io.write_byte(payload_size.to_u8)
    payload_size.times { |offset| io.write_byte((offset & 0xFF).to_u8) }
  end
  io.to_slice
end

private def read_all(reader : ToyRecordReader) : Array(ToyRecordReader::Item)
  list_of_items = [] of ToyRecordReader::Item
  while item = reader.next_item
    list_of_items << item
  end
  list_of_items
end

describe Mica::Core::ByteInput do
  it_satisfies "MICA-CORE-BINARY-FORMAT", "carries a binary format with identical results from bytes and from a trickling stream" do
    bytes = toy_records(2_000)
    from_bytes = read_all(ToyRecordReader.new(bytes))
    from_bytes.size.should eq(2_000)
    {1, 3, 7, 4096}.each do |chunk|
      read_all(ToyRecordReader.new(TrickleIO.new(bytes, chunk))).should eq(from_bytes)
    end
  end

  it_satisfies "MICA-CORE-BINARY-FORMAT", "reports binary errors with a byte offset and no line" do
    bytes = toy_records(10)
    truncated = bytes[0, bytes.size - 1]
    error = expect_raises(Mica::ParseError, /Truncated record payload \(byte \d+\)/) do
      read_all(ToyRecordReader.new(TrickleIO.new(truncated, 5)))
    end
    error.line_number.should eq(0)
    error.position.text?.should be_false
    reserved = expect_raises(Mica::ParseError, /Reserved tag 0/) { read_all(ToyRecordReader.new(Bytes[1, 0, 0, 0])) }
    reserved.byte_offset.should eq(2)
  end

  it_satisfies "MICA-CORE-LIMITS", "enforces the token limit, the input size limit and the work budget" do
    expect_raises(Mica::LimitExceededError, /input size limit/) do
      read_all(ToyRecordReader.new(TrickleIO.new(toy_records(2_000), 4096), size_limit: 10_000_i64))
    end
    budget = Mica::Core::WorkBudget.new(operations_per_unit: 0, base_operations: 1_000)
    error = expect_raises(Mica::WorkBudgetExceededError) { read_all(ToyRecordReader.new(toy_records(100), budget: budget)) }
    error.operations.should be > 1_000
    error.position.text?.should be_false
  end

  it_satisfies "MICA-CORE-LIMITS", "enforces a deadline at each read from a stream" do
    budget = Mica::Core::WorkBudget.new(timeout: 1.nanosecond)
    error = expect_raises(Mica::DeadlineExceededError) do
      read_all(ToyRecordReader.new(TrickleIO.new(toy_records(100), 3), budget: budget))
    end
    error.elapsed.should be > 1.nanosecond
  end

  it_satisfies "MICA-LINEAR-INPUT", "copies each streamed byte O(1) times when compacting the buffer" do
    bytes = toy_records(20_000)
    reader = ToyRecordReader.new(TrickleIO.new(bytes, 3))
    read_all(reader)
    reader.input_bytes_moved.should be <= bytes.size.to_i64 * 2
  end
end

describe Mica::Core::UTF8 do
  it_satisfies "MICA-CORE-UTF8", "encodes every scalar value like the standard library and decodes it back" do
    target = Bytes.new(4)
    (0..0x10FFFF).each do |code|
      next if 0xD800 <= code <= 0xDFFF
      size = Mica::Core::UTF8.encode(code, target)
      expected = code.chr.to_s.to_slice
      raise "encode mismatch at U+#{code.to_s(16)}" unless target[0, size] == expected
      decoded, length = Mica::Core::UTF8.decode(target[0, size])
      raise "decode mismatch at U+#{code.to_s(16)}" unless decoded == code && length == size
    end
  end

  it_satisfies "MICA-CORE-UTF8", "accepts exactly the canonical encodings among all 1-, 2- and 3-byte sequences" do
    target = Bytes.new(4)
    sequence = Bytes.new(3)
    accepted = 0
    (0..0xFF).each do |first|
      sequence[0] = first.to_u8
      (0..0xFF).each do |second|
        sequence[1] = second.to_u8
        (0..0xFF).each do |third|
          sequence[2] = third.to_u8
          code, length = Mica::Core::UTF8.decode(sequence)
          next if length == 0
          size = Mica::Core::UTF8.encode(code, target)
          raise "non-canonical sequence accepted: #{sequence.hexstring}" unless size == length && target[0, size] == sequence[0, size]
          accepted += 1 if length == 3
        end
      end
    end
    # 3-byte scalars: U+0800..U+FFFF minus the 2048 surrogates.
    accepted.should eq(0x10000 - 0x800 - 0x800)
  end

  it "names each problem and finds the first invalid offset" do
    {
      Bytes[0xC0, 0x80]             => Mica::Core::UTF8::Problem::Overlong,
      Bytes[0xED, 0xA0, 0x80]       => Mica::Core::UTF8::Problem::Surrogate,
      Bytes[0xF4, 0x90, 0x80, 0x80] => Mica::Core::UTF8::Problem::OutOfRange,
      Bytes[0xF8, 0x88, 0x80, 0x80] => Mica::Core::UTF8::Problem::InvalidLeadByte,
      Bytes[0x80]                   => Mica::Core::UTF8::Problem::UnexpectedContinuation,
      Bytes[0xE2, 0x82]             => Mica::Core::UTF8::Problem::Truncated,
      Bytes[0xE2, 0x41, 0x41]       => Mica::Core::UTF8::Problem::BadContinuation,
    }.each do |bytes, problem|
      code, length = Mica::Core::UTF8.decode(bytes)
      length.should eq(0)
      Mica::Core::UTF8.problem(code).should eq(problem)
      problem.describe.should_not be_empty
    end
    Mica::Core::UTF8.first_invalid_offset("abéc".to_slice).should be_nil
    Mica::Core::UTF8.first_invalid_offset(Bytes[0x61, 0xC3, 0xA9, 0xFF, 0x61]).should eq(3)
    Mica::Core::UTF8.decode(Bytes.empty).should eq({Mica::Core::UTF8::Problem::Truncated.value, 0})
  end

  it_satisfies "MICA-MEMORY-SAFETY", "never reads past the limit it is given" do
    bytes = "\u20AC\u20AC".to_slice
    Mica::Core::UTF8.decode(bytes, 3, 6).should eq({0x20AC, 3})
    Mica::Core::UTF8.decode(bytes, 3, 5).should eq({Mica::Core::UTF8::Problem::Truncated.value, 0})
    Mica::Core::UTF8.decode(bytes, 6, 6).should eq({Mica::Core::UTF8::Problem::Truncated.value, 0})
    expect_raises(IndexError) { Mica::Core::UTF8.decode(bytes[0, 4], 3, 9) }
  end
end

describe Mica::Core::Encoding do
  it_satisfies "MICA-CORE-ENCODING", "detects byte order marks and resolves labels" do
    Mica::Core::Encoding.from_byte_order_mark(Bytes[0xEF, 0xBB, 0xBF, 0x3C]).should eq({Mica::Core::Encoding::UTF8, 3})
    Mica::Core::Encoding.from_byte_order_mark(Bytes[0xFF, 0xFE, 0, 0]).should eq({Mica::Core::Encoding::UTF32LE, 4})
    Mica::Core::Encoding.from_byte_order_mark(Bytes[0xFF, 0xFE, 0x3C, 0]).should eq({Mica::Core::Encoding::UTF16LE, 2})
    Mica::Core::Encoding.from_byte_order_mark(Bytes[0, 0, 0xFE, 0xFF]).should eq({Mica::Core::Encoding::UTF32BE, 4})
    Mica::Core::Encoding.from_byte_order_mark(Bytes[0x3C]).should be_nil
    Mica::Core::Encoding.from_label("ISO_8859-1").should eq(Mica::Core::Encoding::ISO8859_1)
    Mica::Core::Encoding.from_label("utf-16").should eq(Mica::Core::Encoding::UTF16BE)
    Mica::Core::Encoding.from_label("Shift_JIS").should be_nil
  end
end

private def transcode(bytes : Bytes, encoding : Mica::Core::Encoding, chunk : Int32 = 4096, source_chunk : Int32? = nil) : Bytes
  source = source_chunk ? TrickleIO.new(bytes, source_chunk) : IO::Memory.new(bytes)
  transcoder = Mica::Core::Transcoder.new(source, encoding)
  output = IO::Memory.new
  buffer = Bytes.new(chunk)
  while (count = transcoder.read(buffer)) > 0
    output.write(buffer[0, count])
  end
  output.to_slice
end

describe Mica::Core::Transcoder do
  sample = "aé€\u{1F600}z"
  mutator = Mica::Testing::ByteMutator.new([sample.to_slice])

  it_satisfies "MICA-CORE-ENCODING", "decodes UTF-16, UTF-32 and ISO-8859-1 to UTF-8 at any read size" do
    {
      Mica::Core::Encoding::UTF16BE => mutator.utf16(sample.to_slice, big_endian: true, with_mark: false),
      Mica::Core::Encoding::UTF16LE => mutator.utf16(sample.to_slice, big_endian: false, with_mark: false),
      Mica::Core::Encoding::UTF32BE => mutator.utf32(sample.to_slice, big_endian: true, with_mark: false),
      Mica::Core::Encoding::UTF32LE => mutator.utf32(sample.to_slice, big_endian: false, with_mark: false),
    }.each do |encoding, encoded|
      {1, 2, 3, 4, 5, 4096}.each do |chunk|
        String.new(transcode(encoded, encoding, chunk)).should eq(sample)
      end
      # A source that returns 1 to 3 bytes per read leaves partial code
      # units behind, so refill moves overlapping ranges.
      {1, 2, 3}.each do |source_chunk|
        String.new(transcode(encoded, encoding, 5, source_chunk)).should eq(sample)
      end
      decoded = transcode(encoded, encoding)
      Mica::Core::Transcoder.source_size(encoding, decoded).should eq(encoded.size)
    end
    String.new(transcode(Bytes[0x63, 0xE9, 0xFF], Mica::Core::Encoding::ISO8859_1)).should eq("céÿ")
  end

  it_satisfies "MICA-CORE-ENCODING", "turns invalid units and truncated input into marker bytes, never into replacement characters" do
    lone = Bytes[0xD8, 0x00, 0x00, 0x41]
    transcode(lone, Mica::Core::Encoding::UTF16BE).should eq(Bytes[Mica::Core::Transcoder::INVALID_UNIT, 0x41])
    truncated = Bytes[0x00, 0x41, 0x00]
    transcode(truncated, Mica::Core::Encoding::UTF16BE).should eq(Bytes[0x41, Mica::Core::Transcoder::TRUNCATED_BYTE])
    out_of_range = Bytes[0x00, 0x11, 0x00, 0x00]
    transcode(out_of_range, Mica::Core::Encoding::UTF32BE).should eq(Bytes[Mica::Core::Transcoder::INVALID_UNIT])
    expect_raises(ArgumentError) { Mica::Core::Transcoder.new(IO::Memory.new, Mica::Core::Encoding::UTF8) }
  end
end

# An IO that counts the reads made on it.
private class CountingIO < IO
  getter reads = 0

  def initialize(@bytes : Bytes)
    @offset = 0
  end

  def read(slice : Bytes) : Int32
    @reads += 1
    count = Math.min(Math.min(1, slice.size), @bytes.size - @offset)
    return 0 if count <= 0
    slice[0, count].copy_from(@bytes[@offset, count])
    @offset += count
    count
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

describe "Mica::Core::Transcoder reads" do
  it_satisfies "MICA-CORE-LIMITS", "returns to its caller after one round of source reads" do
    mutator = Mica::Testing::ByteMutator.new(["x".to_slice])
    encoded = mutator.utf16(("abc" * 1_000).to_slice, big_endian: true, with_mark: false)
    source = CountingIO.new(encoded)
    transcoder = Mica::Core::Transcoder.new(source, Mica::Core::Encoding::UTF16BE)
    buffer = Bytes.new(64 * 1024)
    count = transcoder.read(buffer)
    count.should be > 0
    source.reads.should be <= 8
  end
end

describe Mica::Core::ByteSearch do
  it_satisfies "MICA-LINEAR-SEARCH", "finds the same offsets as the standard library in at most 2(n + m) steps" do
    random = Random::PCG32.new(42_u64)
    2_000.times do
      haystack = String.build { |io| random.rand(64).times { io << "ab"[random.rand(2)] } }
      needle = String.build { |io| (1 + random.rand(6)).times { io << "ab"[random.rand(2)] } }
      steps = 0
      found = Mica::Core::ByteSearch.index(haystack.to_slice, needle.to_slice) { |count| steps += count }
      found.should eq(haystack.byte_index(needle))
      steps.should be <= 2 * (haystack.bytesize + needle.bytesize)
    end
    Mica::Core::ByteSearch.index("abc".to_slice, Bytes.empty).should eq(0)
    reports = [] of Int32
    Mica::Core::ByteSearch.index(("a" * 100_000).to_slice, ("a" * 50_000 + "b").to_slice) { |count| reports << count }
    reports.size.should be > 10
    reports.max.should be <= Mica::Core::ByteSearch::STEP_CHUNK
  end
end

describe Mica::Core::Position do
  it "formats text and binary positions" do
    Mica::Core::Position.new(42_i64, 3, 7).to_s.should eq("line 3, column 7, byte 42")
    Mica::Core::Position.new(42_i64).to_s.should eq("byte 42")
    error = Mica::ParseError.new("Bad", Mica::Core::Position.new(5_i64, 1, 6))
    error.message.should eq("Bad (line 1, column 6, byte 5)")
    error.detail.should eq("Bad")
    error.column_number.should eq(6)
  end
end
