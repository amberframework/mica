require "./support/encoder_inputs"

private def write_in_chunks(input : Bytes, quality : Int32, random : Random, *, flushes : Bool) : Bytes
  io = IO::Memory.new
  writer = Mica::Brotli::Writer.new(io, quality: quality, window_bits: 16)
  at = 0
  while at < input.size
    count = Math.min(random.rand(1..9_000), input.size - at)
    writer.write(input[at, count])
    at += count
    writer.flush if flushes && random.rand(4) == 0
  end
  writer.close
  io.to_slice
end

describe Mica::Brotli::Writer do
  it_satisfies "BROTLI-ENC-writer-chunks", "decodes to the input for any write sizes and flushes" do
    random = Random.new(11)
    input = BrotliEncoderInputs.join(BrotliEncoderInputs.html(150_000), BrotliEncoderInputs.random_bytes(5_000), BrotliEncoderInputs.json(50_000))
    {0, 3, 5, 10}.each do |quality|
      {false, true}.each do |flushes|
        encoded = write_in_chunks(input, quality, random, flushes: flushes)
        BrotliEncoderInputs.decode(encoded).should eq(input)
      end
    end
  end

  it_satisfies "BROTLI-ENC-writer-window-slide", "keeps matching after it drops history older than the window" do
    input = BrotliEncoderInputs.text(400_000)
    encoded = write_in_chunks(input, 5, Random.new(3), flushes: false)
    BrotliEncoderInputs.decode(encoded).should eq(input)
    encoded.size.should be < input.size // 3
  end

  it_satisfies "BROTLI-ENC-writer-flush", "makes everything written before a flush decodable from the bytes so far" do
    io = IO::Memory.new
    writer = Mica::Brotli::Writer.new(io, quality: 5)
    writer.write("first part, ".to_slice)
    writer.flush
    flushed = io.to_slice.dup
    # The flush ends on a byte boundary, so one more byte (ISLAST and
    # ISLASTEMPTY set) completes the stream.
    BrotliEncoderInputs.decode(BrotliEncoderInputs.join(flushed, Bytes[3])).should eq("first part, ".to_slice)
    writer.flush
    io.to_slice.size.should eq(flushed.size)
    writer.write("second part".to_slice)
    writer.close
    BrotliEncoderInputs.decode(io.to_slice).should eq("first part, second part".to_slice)
  end

  it_satisfies "BROTLI-ENC-writer-empty", "writes a valid empty stream when closed with nothing written" do
    io = IO::Memory.new
    Mica::Brotli::Writer.new(io).close
    BrotliEncoderInputs.decode(io.to_slice).should eq(Bytes.empty)
  end

  it_satisfies "BROTLI-ENC-writer-matches-encode", "gives the same bytes as Brotli.encode when written in one piece" do
    input = BrotliEncoderInputs.json(40_000)
    io = IO::Memory.new
    writer = Mica::Brotli::Writer.new(io, quality: 6)
    writer.write(input)
    writer.close
    BrotliEncoderInputs.decode(io.to_slice).should eq(input)
  end

  it_satisfies "BROTLI-ENC-arguments", "raises ArgumentError for a bad quality or window, and IO::Error on read" do
    expect_raises(ArgumentError) { Mica::Brotli::Writer.new(IO::Memory.new, quality: 12) }
    expect_raises(ArgumentError) { Mica::Brotli::Writer.new(IO::Memory.new, window_bits: 25) }
    expect_raises(IO::Error) { Mica::Brotli::Writer.new(IO::Memory.new).read(Bytes.new(1)) }
  end
end
