require "./support/streams"

# Decompression bombs against Mica::Brotli: each stops at the exact limit,
# in the one-shot decode and in the Reader, before the guarded bytes exist.
private alias Limits = Mica::Brotli::DecodeLimits

private def read_all(bytes : Bytes, limits : Limits) : Int64
  reader = Mica::Brotli::Reader.new(IO::Memory.new(bytes, false), limits: limits, timeout: nil)
  buffer = Bytes.new(65_536)
  total = 0_i64
  while (count = reader.read(buffer)) > 0
    total += count
  end
  total
end

describe "Mica::Brotli limits" do
  # 64 metablocks of 16 MiB of 'a': 817 bytes that decode to 1 GiB.
  bomb = BrotliStreams.repeat_bomb(64, 16_777_216)

  it_satisfies "BROTLI-LIMIT-output", "stops a 1 GiB bomb at max_output_bytes, one-shot and streaming" do
    bomb.size.should be < 1_024
    limits = Limits.custom(max_output_bytes: 1_000_000_i64, max_ratio: 1_000_000_000_i64)
    error = expect_raises(Mica::Brotli::DecodeLimitError) { Mica::Brotli.decode(bomb, limits: limits, timeout: nil) }
    error.limit.should eq("max_output_bytes")
    error = expect_raises(Mica::Brotli::DecodeLimitError) { read_all(bomb, limits) }
    error.limit.should eq("max_output_bytes")
  end

  it_satisfies "BROTLI-LIMIT-output", "returns exactly max_output_bytes when the stream fits" do
    exact = BrotliStreams.repeat_bomb(1, 1_000_000)
    limits = Limits.custom(max_output_bytes: 1_000_000_i64, max_ratio: 1_000_000_000_i64)
    Mica::Brotli.decode(exact, limits: limits, timeout: nil).size.should eq(1_000_000)
    read_all(exact, limits).should eq(1_000_000)
  end

  it_satisfies "BROTLI-LIMIT-ratio", "stops the bomb at max_ratio once the output passes 1 MiB" do
    error = expect_raises(Mica::Brotli::DecodeLimitError) do
      Mica::Brotli.decode(bomb, limits: Limits::REQUEST_BODY, timeout: nil)
    end
    error.limit.should eq("max_ratio")
  end

  it_satisfies "BROTLI-LIMIT-window", "refuses a window above max_window_bytes before allocating it" do
    large = BrotliStreams.repeat_bomb(1, 4_000, window_bits: 24)
    before = GC.stats.total_bytes
    error = expect_raises(Mica::Brotli::DecodeLimitError) do
      Mica::Brotli.decode(large, limits: Limits::REQUEST_BODY, timeout: nil)
    end
    error.limit.should eq("max_window_bytes")
    (GC.stats.total_bytes - before).should be < 1_048_576
  end

  it_satisfies "BROTLI-LIMIT-metadata", "stops metadata past max_metadata_bytes" do
    writer = BrotliStreams::BitWriter.new
    BrotliStreams.window(writer, 16)
    writer.bits(0, 1).bits(3, 2).bits(0, 1).bits(2, 2).bits(0xFF, 8).bits(0xFF, 8).align # 65,536 bytes
    writer.bytes(Bytes.new(65_536))
    writer.bits(1, 1).bits(1, 1).align
    stream = writer.to_slice
    error = expect_raises(Mica::Brotli::DecodeLimitError) do
      Mica::Brotli.decode(stream, limits: Limits.custom(max_metadata_bytes: 65_535), timeout: nil)
    end
    error.limit.should eq("max_metadata_bytes")
    Mica::Brotli.decode(stream, limits: Limits.custom(max_metadata_bytes: 65_536), timeout: nil).should eq(Bytes.empty)
  end

  it_satisfies "BROTLI-LIMIT-work", "stops at the work budget and at the deadline" do
    tight = Limits.custom(max_ratio: 1_000_000_000_i64, work_per_unit: 0_i64, base_work: 100_000_i64)
    expect_raises(Mica::WorkBudgetExceededError) { Mica::Brotli.decode(bomb, limits: tight, timeout: nil) }
    unbounded = Limits.custom(max_output_bytes: 1_073_741_824_i64, max_ratio: 1_000_000_000_i64)
    expect_raises(Mica::DeadlineExceededError) { Mica::Brotli.decode(bomb, limits: unbounded, timeout: 1.nanosecond) }
  end

  it_satisfies "BROTLI-LIMIT-memory", "decodes a 64 MiB bomb through the Reader in memory bounded by the window" do
    limits = Limits.custom(max_output_bytes: 1_073_741_824_i64, max_ratio: 1_000_000_000_i64)
    small = BrotliStreams.repeat_bomb(4, 16_777_216, window_bits: 18)
    before = GC.stats.total_bytes
    read_all(small, limits).should eq(4_i64 * 16_777_216)
    (GC.stats.total_bytes - before).should be < 2_097_152
  end
end
