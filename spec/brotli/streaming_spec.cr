require "./support/streams"

# An IO that hands out at most *step* bytes per read.
private class TrickleIO < IO
  def initialize(@data : Bytes, @step : Int32)
    @at = 0
  end

  def read(slice : Bytes) : Int32
    count = Math.min(Math.min(slice.size, @step), @data.size - @at)
    slice.copy_from(@data.to_unsafe + @at, count)
    @at += count
    count
  end

  def write(slice : Bytes) : NoReturn
    raise IO::Error.new("read-only")
  end
end

describe Mica::Brotli::Reader do
  it_satisfies "BROTLI-API-streaming", "gives the one-shot result whatever the input chunks and read sizes" do
    streams = [
      BrotliStreams.stored("streamed".to_slice),
      BrotliStreams.repeat_bomb(3, 70_000, window_bits: 16),
      BrotliStreams.repeat_bomb(2, 300_000, window_bits: 18),
    ]
    streams.each do |encoded|
      expected = Mica::Brotli.decode(encoded, limits: BrotliStreams::LIMITS, timeout: nil)
      [1, 3, 7, 4096].each do |step|
        [1, 13, 65_536].each do |read_size|
          reader = Mica::Brotli::Reader.new(TrickleIO.new(encoded, step), limits: BrotliStreams::LIMITS, timeout: nil)
          output = IO::Memory.new
          buffer = Bytes.new(read_size)
          while (count = reader.read(buffer)) > 0
            output.write(buffer[0, count])
          end
          output.to_slice.should eq(expected)
          reader.produced.should eq(expected.size)
        end
      end
    end
  end

  it_satisfies "BROTLI-API-streaming", "wraps its ring around the window and keeps back references across the wrap" do
    # 300,000-byte metablocks in a 64 KiB window: the ring wraps many times.
    encoded = BrotliStreams.repeat_bomb(4, 300_000, window_bits: 16)
    reader = Mica::Brotli::Reader.new(IO::Memory.new(encoded, false), limits: BrotliStreams::LIMITS, timeout: nil)
    reader.gets_to_end.to_slice.should eq(Bytes.new(1_200_000, 'a'.ord.to_u8))
  end

  it "closes its source when sync_close is set" do
    source = IO::Memory.new(BrotliStreams.stored("x".to_slice), false)
    reader = Mica::Brotli::Reader.new(source, limits: BrotliStreams::LIMITS, timeout: nil, sync_close: true)
    reader.close
    source.closed?.should be_true
    expect_raises(IO::Error) { reader.read(Bytes.new(1)) }
  end
end
