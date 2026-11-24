# Release-build fuzz campaign over Mica::HTTP2's frame codec and
# Mica::HPACK's decoder.
#
#   crystal-alpha build --release fuzz/http2_campaign.cr -o bin/http2_campaign
#   bin/http2_campaign SEED COUNT
#
# Each of COUNT cases is one frame stream: half are serialized random frames
# (whose parse must give back the same frames), half are those streams
# mutated or plain random bytes. Every stream is parsed at once and in
# random chunks (one byte at a time for every tenth), and the frames and
# errors must match; only Mica errors may be raised, and the parse may
# allocate at most 4 bytes per stream byte plus 256 KiB. Every case also
# decodes one random or mutated header block with a PUBLIC_SERVER HPACK
# decoder that shares its context with an encoder until a block fails, which may raise only Mica errors and allocate at most 8 bytes per
# block byte plus 64 KiB plus the fields it returns.
#
# Prints one summary line; each failure prints a FAIL line with SEED:INDEX.
# Exits 1 on any failure.
require "./http2_fuzz"

usage = "usage: http2_campaign SEED COUNT"
seed = (ARGV[0]? || abort(usage)).to_i64
count = (ARGV[1]? || abort(usage)).to_i
random = Random.new(seed)
failures = 0
round_trips = 0
frames_parsed = 0
connection_errors = 0
hpack_rejects = 0
started = Time.instant

report = ->(index : Int32, detail : String, bytes : Bytes) do
  failures += 1
  puts "FAIL #{seed}:#{index} #{detail} bytes=#{bytes[0, Math.min(bytes.size, 256)].hexstring}" if failures <= 50
end

encoder = Mica::HPACK::Encoder.new
decoder = Mica::HPACK::Decoder.new(limits: Mica::HPACK::DecodeLimits::PUBLIC_SERVER)
count.times do |index|
  valid = random.rand(2) == 0
  list_of_frames = HTTP2Fuzz.random_frames(random, random.rand(1..6))
  bytes = HTTP2Fuzz.serialize(list_of_frames)
  unless valid
    if random.rand(4) == 0
      bytes = Bytes.new(random.rand(0..300)) { random.rand(256).to_u8 }
    else
      random.rand(1..6).times { bytes[random.rand(bytes.size)] = random.rand(256).to_u8 } unless bytes.empty?
    end
  end
  begin
    before = GC.stats.total_bytes
    whole = HTTP2Fuzz.outcome(bytes)
    allocated = GC.stats.total_bytes - before
    # The outcome strings themselves are part of the allocation; they are
    # small next to the bound.
    report.call(index, "allocated #{allocated} bytes", bytes) if allocated > bytes.size * 4 + 262_144
    frames_parsed += whole.count { |event| !event.starts_with?("connection") && !event.starts_with?("stream") && !event.starts_with?("limit") }
    connection_errors += 1 if whole.last?.try(&.starts_with?("connection"))
    if valid
      if whole == list_of_frames.map(&.inspect)
        round_trips += 1
      else
        report.call(index, "parse(serialize(frames)) differs", bytes)
      end
    end
    chunks = index % 10 == 0 ? [1] : Array.new(4) { random.rand(1..64) }
    report.call(index, "chunked parse differs", bytes) unless HTTP2Fuzz.outcome(bytes, chunks) == whole
  rescue error : Exception
    report.call(index, "raised #{error.class}: #{error.message}", bytes)
  end

  block = encoder.encode([Mica::HPACK::Header.new("x-#{random.rand(100)}", "v" * random.rand(0..50)),
                          Mica::HPACK::Header.new(":path", "/#{random.rand(1_000)}")])
  block = Bytes.new(random.rand(0..128)) { random.rand(256).to_u8 } if random.rand(2) == 0
  random.rand(0..3).times { block[random.rand(block.size)] = random.rand(256).to_u8 } unless block.empty?
  begin
    before = GC.stats.total_bytes
    produced = decoder.decode(block).sum { |header| header.size + 64 }
    allocated = GC.stats.total_bytes - before
    report.call(index, "HPACK allocated #{allocated} bytes", block) if allocated > block.size * 8 + 65_536 + produced
  rescue Mica::Error
    hpack_rejects += 1
    # The contexts restart together after a rejected block.
    encoder = Mica::HPACK::Encoder.new
    decoder = Mica::HPACK::Decoder.new(limits: Mica::HPACK::DecodeLimits::PUBLIC_SERVER)
  rescue error : Exception
    report.call(index, "HPACK raised #{error.class}: #{error.message}", block)
  end
end
elapsed = (Time.instant - started).total_seconds
puts "http2_campaign seed=#{seed} streams=#{count} round_trips=#{round_trips} frames=#{frames_parsed} " \
     "connection_errors=#{connection_errors} header_blocks=#{count} hpack_rejects=#{hpack_rejects} failures=#{failures} " \
     "seconds=#{elapsed.round(1)}"
exit(failures == 0 ? 0 : 1)
