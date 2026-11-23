# Round-trip campaign for the Mica::Brotli encoder: every stream Mica
# writes must decode to its input in google/brotli 1.2.1's libbrotlidec
# (libbrotli.a, built out of tree by fuzz/build_brotli_reference.sh and
# linked only into this harness) and in Mica's own decoder.
#
#   crystal-alpha build --release --link-flags DIR/libbrotli.a fuzz/brotli_encode_campaign.cr -o brotli_encode_campaign
#   brotli_encode_campaign SEED CASES
#
# Each case draws a quality (0 to 11), a window (10 to 24), an input
# family (text, JSON, HTML, random, runs, binary records, repeats,
# dictionary words, mixtures) and a size (log-uniform up to 256 KiB); one
# case in eight goes through Mica::Brotli::Writer with random write sizes
# and flushes. A failing case prints its seed and parameters and writes
# its input to brotli-encode-failure-SEED-CASE.bin.
require "../src/mica/brotli"

lib LibRef
  fun BrotliDecoderDecompress(encoded_size : LibC::SizeT, encoded : UInt8*, decoded_size : LibC::SizeT*, decoded : UInt8*) : Int32
end

LIMITS = Mica::Brotli::DecodeLimits.custom(max_output_bytes: 1_i64 << 30, max_ratio: 1_000_000_000_i64,
  max_window_bytes: 16_777_216, max_metadata_bytes: 16_777_216)

WORDS = %w(the of and to in is that for it as with was on be by at this have from or one had not but what all were when
  we there can an your which their said if do will each about how up out them then she many some so these would other
  into has more her two like him see time could no make than first been its who now people my made over did down only
  way find use may water long little very after words called just where most know government information development)

def reference_decode(encoded : Bytes, size : Int32) : Bytes?
  output = Bytes.new(size + 1)
  produced = LibC::SizeT.new(output.size)
  return nil unless LibRef.BrotliDecoderDecompress(encoded.size, encoded.to_unsafe, pointerof(produced), output.to_unsafe) == 1
  output[0, produced.to_i32]
end

def mica_decode(encoded : Bytes) : Bytes?
  Mica::Brotli.decode(encoded, limits: LIMITS, timeout: nil)
rescue error : Mica::Brotli::MalformedStreamError | Mica::Brotli::DecodeLimitError
  STDERR.puts "  mica: #{error.message}"
  nil
end

def generate(family : Int32, size : Int32, random : Random) : Bytes
  io = IO::Memory.new(size + 64)
  case family
  when 0 # text
    while io.size < size
      io << WORDS[random.rand(WORDS.size)] << (random.rand(12) == 0 ? ".\n" : " ")
    end
  when 1 # JSON
    io << "["
    while io.size < size
      io << %({"id":) << random.rand(100_000) << %(,"name":") << WORDS[random.rand(WORDS.size)] << %(","ok":) << (random.rand(2) == 0) << "},"
    end
  when 2 # HTML
    while io.size < size
      io << %(<li class="item"><a href="/p/) << random.rand(1000) << %(">) << WORDS[random.rand(WORDS.size)] << "</a></li>\n"
    end
  when 3 # random bytes
    size.times { io.write_byte(random.rand(256).to_u8) }
  when 4 # runs of a few byte values
    while io.size < size
      byte = random.rand(4).to_u8
      random.rand(1..300).times { io.write_byte(byte) }
    end
  when 5 # binary records with small counters
    counter = random.rand(1000)
    while io.size < size
      io.write_bytes(counter, IO::ByteFormat::LittleEndian)
      io.write_bytes(random.rand(16).to_u16, IO::ByteFormat::LittleEndian)
      counter += random.rand(3)
    end
  when 6 # a short random pattern repeated with mutations
    pattern = Bytes.new(random.rand(1..64)) { random.rand(256).to_u8 }
    while io.size < size
      io.write(pattern)
      pattern[random.rand(pattern.size)] = random.rand(256).to_u8 if random.rand(4) == 0
    end
  when 7 # dictionary words with capitals and punctuation
    while io.size < size
      word = WORDS[random.rand(WORDS.size)]
      word = word.capitalize if random.rand(5) == 0
      io << word << {" ", ", ", ". ", "\n"}[random.rand(4)]
    end
  else # a mixture of the others
    while io.size < size
      io.write(generate(random.rand(8), random.rand(1..4096), random))
    end
  end
  io.to_slice[0, size]
end

def encode_streaming(input : Bytes, quality : Int32, window_bits : Int32, random : Random) : Bytes
  io = IO::Memory.new
  writer = Mica::Brotli::Writer.new(io, quality: quality, window_bits: window_bits)
  at = 0
  while at < input.size
    count = Math.min(random.rand(1..20_000), input.size - at)
    writer.write(input[at, count])
    at += count
    writer.flush if random.rand(6) == 0
  end
  writer.close
  io.to_slice
end

seed = (ARGV[0]? || "1").to_u64
cases = (ARGV[1]? || "1000").to_i
random = Random.new(seed)
failures = 0
streamed = 0
input_bytes = 0_i64
output_bytes = 0_i64
by_quality = Array.new(12, 0)
started = Time.instant
cases.times do |index|
  quality = random.rand(12)
  window_bits = random.rand(10..24)
  family = random.rand(9)
  size = random.rand(8) == 0 ? random.rand(0..2) : (2.0 ** random.rand(0.0..18.0)).to_i
  size = Math.min(size, 65_536) if quality >= 10
  input = generate(family, size, random)
  streaming = random.rand(8) == 0
  encoded = streaming ? encode_streaming(input, quality, window_bits, random) : Mica::Brotli.encode(input, quality: quality, window_bits: window_bits)
  reference_ok = reference_decode(encoded, input.size) == input
  mica_ok = mica_decode(encoded) == input
  by_quality[quality] += 1
  streamed += 1 if streaming
  input_bytes += input.size
  output_bytes += encoded.size
  unless reference_ok && mica_ok
    failures += 1
    path = "brotli-encode-failure-#{seed}-#{index}.bin"
    File.write(path, input)
    puts "FAIL seed=#{seed} case=#{index} quality=#{quality} window_bits=#{window_bits} family=#{family} size=#{size} streaming=#{streaming} libbrotlidec=#{reference_ok} mica=#{mica_ok} input=#{path}"
  end
end
seconds = (Time.instant - started).total_seconds
puts "seed=#{seed} cases=#{cases} failures=#{failures} streamed=#{streamed} input_bytes=#{input_bytes} output_bytes=#{output_bytes} per_quality=#{by_quality.join(",")} seconds=#{seconds.round(1)}"
exit(failures == 0 ? 0 : 1)
