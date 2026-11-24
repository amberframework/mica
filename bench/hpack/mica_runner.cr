# HPACK decode runner for Mica (bench/hpack/run_ab.rb):
#
#   crystal-alpha build --release bench/hpack/mica_runner.cr -o bench/bin/hpack/mica_runner
#   bench/bin/hpack/mica_runner CORPUS WARMUP PASSES
#
# Decodes every block of CORPUS (bench/hpack/make_corpus.rb) WARMUP times,
# then PASSES timed times, and prints one line per timed pass:
# "pass NANOSECONDS FIELDS FIELD_BYTES".
require "../../src/mica"

record Item, kind : Char, size : Int32, block : Bytes

def load(path : String) : Array(Item)
  items = [] of Item
  File.open(path) do |file|
    while kind = file.read_char
      case kind
      when 'S' then items << Item.new('S', 0, Bytes.empty)
      when 'T' then items << Item.new('T', file.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32, Bytes.empty)
      else
        block = Bytes.new(file.read_bytes(UInt32, IO::ByteFormat::BigEndian))
        file.read_fully(block)
        items << Item.new('B', block.size, block)
      end
    end
  end
  items
end

LIMITS = Mica::HPACK::DecodeLimits.custom(max_header_list_bytes: 1_048_576, max_header_block_bytes: 1_048_576,
  max_table_bytes: 65_536)

def pass(items : Array(Item)) : {Int64, Int64}
  fields = 0_i64
  field_bytes = 0_i64
  decoder = Mica::HPACK::Decoder.new(limits: LIMITS)
  items.each do |item|
    case item.kind
    when 'S' then decoder = Mica::HPACK::Decoder.new(limits: LIMITS)
    when 'T' then decoder.max_table_size = item.size
    else
      decoder.decode(item.block) do |header|
        fields += 1
        field_bytes += header.name.bytesize + header.value.bytesize
      end
    end
  end
  {fields, field_bytes}
end

items = load(ARGV[0])
warmup = ARGV[1].to_i
passes = ARGV[2].to_i
warmup.times { pass(items) }
passes.times do
  started = Time.instant
  fields, field_bytes = pass(items)
  elapsed = (Time.instant - started).total_nanoseconds.to_i64
  STDOUT << "pass " << elapsed << ' ' << fields << ' ' << field_bytes << '\n'
end
