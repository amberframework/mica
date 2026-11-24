# Release-build HPACK differential against nghttp2 1.71.0's HPACK, run out
# of tree through fuzz/hpack_nghttp2/harness.c (built by
# fuzz/hpack_nghttp2/build.sh).
#
#   crystal-alpha build --release fuzz/hpack_differential.cr -o bin/hpack_differential
#   bin/hpack_differential HARNESS MODE SEED COUNT
#
# MODE is one of:
# - encode: Mica encodes COUNT random header lists (contexts of 100 lists,
#   with table size changes); nghttp2's inflater decodes every block, and
#   its fields, never-indexed flags and table size must match the list's.
# - deflate: nghttp2's deflater encodes COUNT random lists; Mica decodes
#   them to the same fields and table size.
# - decode: COUNT random and mutated blocks go to both decoders, in shared
#   contexts; both must accept with the same fields and table size, or
#   both reject (the error class may differ). Mica's allocation per block
#   must stay within 8 bytes per block byte plus 64 KiB plus the fields it
#   returns.
#
# Prints one summary line; each disagreement prints a FAIL line with the
# case's SEED:INDEX and the block in hex. Exits 1 on any disagreement.
require "../src/mica"

alias Header = Mica::HPACK::Header

LIMITS = Mica::HPACK::DecodeLimits.custom(max_header_list_bytes: 16_777_216, max_header_block_bytes: 16_777_216,
  max_table_bytes: 65_536, base_work: 1_000_000_000_i64)

class Harness
  @process : Process
  @input : IO
  @output : IO

  def initialize(path : String)
    @process = Process.new(path, input: :pipe, output: :pipe, error: :inherit)
    @input = @process.input
    @output = @process.output
  end

  def command(op : Char, value : Int) : Nil
    @input.write_byte(op.ord.to_u8)
    @input.write_bytes(value.to_u32, IO::ByteFormat::BigEndian)
  end

  # Returns the fields and table size, or nil when nghttp2 rejects.
  def inflate(block : Bytes) : {Array(Header), Int32}?
    command('D', block.size)
    @input.write(block)
    @input.flush
    status = @output.read_byte
    return nil if status == 'E'.ord
    raise "harness answered #{status.inspect}" unless status == 'K'.ord
    count = read_u32
    list = Array(Header).new(count) do
      name = read_string
      value = read_string
      Header.new(name, value, @output.read_byte == 1)
    end
    {list, read_u32}
  end

  def deflate(list : Array(Header)) : Bytes
    command('H', list.size)
    list.each do |header|
      write_string(header.name)
      write_string(header.value)
      @input.write_byte(header.never_indexed? ? 1_u8 : 0_u8)
    end
    @input.flush
    raise "harness did not answer B" unless @output.read_byte == 'B'.ord
    bytes = Bytes.new(read_u32)
    @output.read_fully(bytes)
    bytes
  end

  def close : Nil
    @input.write_byte('Q'.ord.to_u8)
    @input.close
    @process.wait
  end

  private def read_u32 : Int32
    @output.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32
  end

  private def read_string : String
    bytes = Bytes.new(read_u32)
    @output.read_fully(bytes)
    String.new(bytes)
  end

  private def write_string(text : String) : Nil
    @input.write_bytes(text.bytesize.to_u32, IO::ByteFormat::BigEndian)
    @input.write(text.to_slice)
  end
end

NAMES = {":method", ":path", ":authority", ":scheme", ":status", "accept", "accept-encoding", "cookie", "set-cookie",
         "authorization", "proxy-authorization", "user-agent", "content-type", "content-length", "date", "etag",
         "x-request-id", "cache-control", "via", "x-forwarded-for"}

def random_text(random : Random, max : Int32) : String
  length = random.rand(0..max)
  case random.rand(3)
  when 0 then String.new(Bytes.new(length) { random.rand(256).to_u8 })
  when 1 then String.new(Bytes.new(length) { random.rand(0x20_u8..0x7e_u8) })
  else        "v#{random.rand(64)}"
  end
end

def random_list(random : Random) : Array(Header)
  Array.new(random.rand(0..16)) do
    name = random.rand(5) == 0 ? random_text(random, 24) : NAMES[random.rand(NAMES.size)]
    value = random.rand(4) == 0 ? random_text(random, 300) : random_text(random, 24)
    Header.new(name, value, random.rand(20) == 0)
  end
end

def fields(list : Array(Header)) : Array({String, String})
  list.map { |header| {header.name, header.value} }
end

def mica_decode(decoder : Mica::HPACK::Decoder, block : Bytes) : {Array(Header), Int32}?
  {decoder.decode(block), decoder.table_size}
rescue Mica::Error
  nil
end

usage = "usage: hpack_differential HARNESS encode|deflate|decode SEED COUNT"
harness_path = ARGV[0]? || abort(usage)
mode = ARGV[1]? || abort(usage)
seed = (ARGV[2]? || abort(usage)).to_i64
count = (ARGV[3]? || abort(usage)).to_i
random = Random.new(seed)
harness = Harness.new(harness_path)
started = Time.instant
disagreements = 0
both_reject = 0
agreements = 0
max_allocation_ratio = 0.0

fail = ->(index : Int32, detail : String, block : Bytes) do
  disagreements += 1
  puts "FAIL #{seed}:#{index} #{detail} block=#{block.hexstring}" if disagreements <= 50
end

case mode
when "encode"
  encoder = Mica::HPACK::Encoder.new
  count.times do |index|
    if index % 100 == 0
      encoder = Mica::HPACK::Encoder.new(huffman: random.rand(4) != 0)
      harness.command('I', 4_096)
    end
    if random.rand(40) == 0
      size = random.rand(0..8_192)
      encoder.max_table_size = size
      harness.command('S', size)
    end
    list = random_list(random)
    block = encoder.encode(list)
    result = harness.inflate(block)
    expected = list.map { |header| header.copy_with(never_indexed: header.never_indexed? || encoder.never_indexed_names.includes?(header.name)) }
    if result.nil?
      fail.call(index, "nghttp2 rejected Mica's block", block)
    elsif result[0] != expected || result[1] != encoder.table_size
      fail.call(index, "nghttp2 decoded #{result[0].size} fields, table #{result[1]} (Mica table #{encoder.table_size})", block)
    else
      agreements += 1
    end
  end
when "deflate"
  decoder = Mica::HPACK::Decoder.new(limits: LIMITS)
  count.times do |index|
    if index % 100 == 0
      decoder = Mica::HPACK::Decoder.new(limits: LIMITS)
      harness.command('Z', 4_096)
    end
    if random.rand(40) == 0
      size = random.rand(0..4_096)
      decoder.max_table_size = size
      harness.command('T', size)
    end
    list = random_list(random)
    block = harness.deflate(list)
    result = mica_decode(decoder, block)
    if result.nil?
      fail.call(index, "Mica rejected nghttp2's block", block)
      decoder = Mica::HPACK::Decoder.new(limits: LIMITS)
      harness.command('Z', 4_096)
    elsif fields(result[0]) != fields(list)
      fail.call(index, "Mica decoded different fields", block)
    else
      agreements += 1
    end
  end
when "decode"
  decoder = Mica::HPACK::Decoder.new(limits: LIMITS)
  encoder = Mica::HPACK::Encoder.new
  harness.command('I', 4_096)
  count.times do |index|
    block = case random.rand(4)
            when 0
              Bytes.new(random.rand(0..64)) { random.rand(256).to_u8 }
            when 1
              # Representation-shaped noise: first octets of every kind.
              io = IO::Memory.new
              random.rand(1..8).times do
                io.write_byte({0x80, 0x40, 0x20, 0x10, 0x00}[random.rand(5)].to_u8 | random.rand(16).to_u8)
                random.rand(0..6).times { io.write_byte(random.rand(256).to_u8) }
              end
              io.to_slice
            else
              valid = encoder.encode(random_list(random))
              random.rand(0..3).times { valid[random.rand(valid.size)] = random.rand(256).to_u8 } unless valid.empty?
              valid = valid[0, random.rand(valid.size + 1)] if random.rand(8) == 0
              valid
            end
    before = GC.stats.total_bytes
    ours = mica_decode(decoder, block)
    allocated = (GC.stats.total_bytes - before).to_f
    produced = ours ? ours[0].sum { |header| header.size + 64 } : 0
    ratio = (allocated - produced) / (block.size * 8 + 65_536)
    max_allocation_ratio = ratio if ratio > max_allocation_ratio
    fail.call(index, "Mica allocated #{allocated.to_i} bytes", block) if ratio > 1.0
    theirs = harness.inflate(block)
    if ours.nil? && theirs.nil?
      both_reject += 1
    elsif ours.nil? || theirs.nil?
      fail.call(index, ours.nil? ? "Mica rejected, nghttp2 accepted" : "nghttp2 rejected, Mica accepted", block)
    elsif fields(ours[0]) != fields(theirs[0]) || ours[0].map(&.never_indexed?) != theirs[0].map(&.never_indexed?) ||
          ours[1] != theirs[1]
      fail.call(index, "different fields or table size", block)
    else
      agreements += 1
    end
    # A rejected block leaves both contexts unusable: start new ones.
    # Every 50 blocks the contexts restart anyway, so the table is often
    # small and mutated indices hit it.
    if ours.nil? || theirs.nil? || index % 50 == 49
      decoder = Mica::HPACK::Decoder.new(limits: LIMITS)
      encoder = Mica::HPACK::Encoder.new(huffman: random.rand(2) == 0)
      harness.command('I', 4_096)
    end
  end
else
  abort(usage)
end
harness.close
elapsed = (Time.instant - started).total_seconds
puts "hpack_differential mode=#{mode} seed=#{seed} cases=#{count} agreements=#{agreements} both_reject=#{both_reject} " \
     "disagreements=#{disagreements} max_allocation_ratio=#{max_allocation_ratio.round(4)} seconds=#{elapsed.round(1)} " \
     "reference=nghttp2-1.71.0"
exit(disagreements == 0 ? 0 : 1)
