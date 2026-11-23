# Differential decode campaign: Mica::Brotli against google/brotli 1.2.1
# (libbrotli.a, built out of tree by fuzz/build_brotli_reference.sh and
# linked only into this harness).
#
#   crystal-alpha build --release --link-flags DIR/libbrotli.a fuzz/brotli_differential.cr -o brotli_differential
#   brotli_differential SEED CASES
#
# Each case compresses a generated input with the reference at a random
# quality (0 to 11), window (10 to 24) and mode, then checks: Mica decodes
# the stream to the input, one-shot and (one case in eight) trickled
# through Mica::Brotli::Reader in 1- to 7-byte reads; and for two mutations
# of the stream (bit flips, truncation, overwritten bytes, appended bytes)
# Mica and the reference both reject it or both return the same bytes.
require "../src/mica/brotli"

lib LibRef
  fun BrotliEncoderCompress(quality : Int32, lgwin : Int32, mode : Int32, input_size : LibC::SizeT, input : UInt8*, encoded_size : LibC::SizeT*, encoded : UInt8*) : Int32
  fun BrotliEncoderMaxCompressedSize(input_size : LibC::SizeT) : LibC::SizeT
  fun BrotliDecoderCreateInstance(alloc : Void*, free : Void*, opaque : Void*) : Void*
  fun BrotliDecoderDestroyInstance(state : Void*)
  fun BrotliDecoderDecompressStream(state : Void*, available_in : LibC::SizeT*, next_in : UInt8**, available_out : LibC::SizeT*, next_out : UInt8**, total_out : LibC::SizeT*) : Int32
end

LIMIT = 1 << 22

# Returns the reference's output, or nil when it rejects the stream (an
# error, truncated input, bytes after the end, or more than LIMIT bytes).
def reference_decode(input : Bytes) : Bytes?
  state = LibRef.BrotliDecoderCreateInstance(nil, nil, nil)
  output = Bytes.new(LIMIT + 1)
  avail_in = LibC::SizeT.new(input.size)
  next_in = input.to_unsafe
  avail_out = LibC::SizeT.new(output.size)
  next_out = output.to_unsafe
  total = LibC::SizeT.new(0)
  result = LibRef.BrotliDecoderDecompressStream(state, pointerof(avail_in), pointerof(next_in), pointerof(avail_out), pointerof(next_out), pointerof(total))
  LibRef.BrotliDecoderDestroyInstance(state)
  # 1 = success; anything else is a rejection.
  return nil unless result == 1 && avail_in == 0 && total <= LIMIT
  output[0, total.to_i32].dup
end

LIMITS = Mica::Brotli::DecodeLimits.custom(max_output_bytes: LIMIT.to_i64, max_ratio: 1_000_000_000_i64,
  max_window_bytes: 16_777_216, max_metadata_bytes: 16_777_216)

def mica_decode(input : Bytes) : Bytes?
  Mica::Brotli.decode(input, limits: LIMITS, timeout: nil)
rescue Mica::Brotli::MalformedStreamError | Mica::Brotli::DecodeLimitError
  nil
end

# An IO that hands output 1 to 7 bytes per read.
class TrickleIO < IO
  def initialize(@data : Bytes, @random : Random)
    @at = 0
  end

  def read(slice : Bytes) : Int32
    count = Math.min(Math.min(slice.size, @random.rand(1..7)), @data.size - @at)
    slice.copy_from(@data.to_unsafe + @at, count)
    @at += count
    count
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("read-only")
  end
end

def mica_trickle(input : Bytes, random : Random) : Bytes?
  reader = Mica::Brotli::Reader.new(TrickleIO.new(input, random), limits: LIMITS, timeout: nil)
  output = IO::Memory.new
  buffer = Bytes.new(random.rand(1..9000))
  while (count = reader.read(buffer)) > 0
    output.write(buffer[0, count])
  end
  output.to_slice
rescue Mica::Brotli::MalformedStreamError | Mica::Brotli::DecodeLimitError
  nil
end

WORDS = %w(the of and to in is you that it he was for on are as with his they at be this from I have or by one had not but what all were when we there can an your which their said if do will each about how up output them then she many some so these would other into has more her two like him see time could no make than first been its who now people my made over did down only way find use may water long little very after words called just where most know)

def make_input(random : Random) : Bytes
  size = case random.rand(10)
         when 0..3 then random.rand(0..256)
         when 4..7 then random.rand(0..8192)
         else           random.rand(0..131072)
         end
  case random.rand(5)
  when 0
    Bytes.new(size) { random.rand(256).to_u8 }
  when 1
    alphabet = random.rand(1..8)
    Bytes.new(size) { (97 + random.rand(alphabet)).to_u8 }
  when 2
    text = String.build do |io|
      while io.bytesize < size
        word = WORDS.sample(random)
        word = word.capitalize if random.rand(8) == 0
        word = word.upcase if random.rand(30) == 0
        io << word << [" ", " ", " ", ", ", ". ", "\n", "=\"", "\">"].sample(random)
      end
    end
    text.to_slice[0, Math.min(size, text.bytesize)]
  when 3
    period = random.rand(1..300)
    seed = Bytes.new(period) { random.rand(256).to_u8 }
    Bytes.new(size) { |i| random.rand(50) == 0 ? random.rand(256).to_u8 : seed[i % period] }
  else
    json = String.build do |io|
      io << "["
      while io.bytesize < size
        io << %({"id":#{random.rand(100000)},"name":"user#{random.rand(1000)}","active":#{random.rand(2) == 1},"score":#{random.rand(1000) / 10.0}},)
      end
      io << "{}]"
    end
    json.to_slice[0, Math.min(size, json.bytesize)]
  end
end

def mutate(stream : Bytes, random : Random) : Bytes
  copy = stream.dup
  case random.rand(4)
  when 0
    random.rand(1..4).times { copy[random.rand(copy.size)] ^= (1 << random.rand(8)).to_u8 } unless copy.empty?
    copy
  when 1
    copy.empty? ? copy : copy[0, random.rand(copy.size)]
  when 2
    random.rand(1..8).times { copy[random.rand(copy.size)] = random.rand(256).to_u8 } unless copy.empty?
    copy
  else
    extra = Bytes.new(random.rand(1..4)) { random.rand(256).to_u8 }
    joined = Bytes.new(copy.size + extra.size)
    joined.copy_from(copy.to_unsafe, copy.size)
    (joined.to_unsafe + copy.size).copy_from(extra.to_unsafe, extra.size)
    joined
  end
end

seed = ARGV[0].to_u64
cases = ARGV[1].to_i
random = Random::PCG32.new(seed)
stats = Hash(String, Int64).new(0_i64)
disagreements = 0
started = Time.instant
cases.times do |index|
  input = make_input(random)
  quality = random.rand(0..11)
  lgwin = random.rand(10..24)
  mode = random.rand(0..2)
  encoded = Bytes.new(LibRef.BrotliEncoderMaxCompressedSize(input.size) + 16)
  encoded_size = LibC::SizeT.new(encoded.size)
  abort "reference encoder failed" unless LibRef.BrotliEncoderCompress(quality, lgwin, mode, input.size, input.to_unsafe, pointerof(encoded_size), encoded.to_unsafe) == 1
  stream = encoded[0, encoded_size.to_i32]
  # Direction 1: Mica decodes the reference's output, whole and trickled.
  mica = mica_decode(stream)
  if mica != input
    disagreements += 1
    puts "DISAGREE valid case=#{index} q=#{quality} lgwin=#{lgwin} size=#{input.size}"
    File.write("disagree-#{seed}-#{index}.br", stream)
  end
  stats["valid"] += 1
  if random.rand(8) == 0
    trickled = mica_trickle(stream, random)
    if trickled != input
      disagreements += 1
      puts "DISAGREE trickle case=#{index}"
      File.write("disagree-trickle-#{seed}-#{index}.br", stream)
    end
    stats["trickled"] += 1
  end
  # Mutated streams: both decoders agree on rejection or on the bytes.
  2.times do
    mutated = mutate(stream, random)
    expected = reference_decode(mutated)
    actual = mica_decode(mutated)
    stats[expected ? "mutated_accepted" : "mutated_rejected"] += 1
    if expected != actual
      disagreements += 1
      puts "DISAGREE mutated case=#{index} reference=#{expected ? expected.size : "reject"} mica=#{actual ? actual.size : "reject"}"
      File.write("disagree-mutated-#{seed}-#{index}-#{stats["mutated_accepted"] + stats["mutated_rejected"]}.br", mutated)
    end
  end
end
puts "seed=#{seed} cases=#{cases} #{stats.map { |k, v| "#{k}=#{v}" }.join(" ")} disagreements=#{disagreements} seconds=#{(Time.instant - started).total_seconds.round(1)}"
exit(disagreements == 0 ? 0 : 1)
