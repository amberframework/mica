require "./support/encoder_inputs"

private def round_trip(input : Bytes, quality : Int32, window_bits : Int32 = 22) : Bytes
  encoded = Mica::Brotli.encode(input, quality: quality, window_bits: window_bits)
  BrotliEncoderInputs.decode(encoded).should eq(input)
  encoded
end

describe Mica::Brotli do
  describe ".encode" do
    it_satisfies "BROTLI-ENC-roundtrip-qualities", "round-trips every input shape at every quality" do
      BrotliEncoderInputs.all.each do |name, input|
        (0..11).each do |quality|
          encoded = round_trip(input, quality)
          (name == "random" || input.size < 2 || encoded.size < input.size).should be_true
        end
      end
    end

    it_satisfies "BROTLI-ENC-roundtrip-windows", "round-trips with windows from 10 to 24 bits, also with matches the window cuts off" do
      input = BrotliEncoderInputs.join(BrotliEncoderInputs.text(5_000), BrotliEncoderInputs.random_bytes(3_000), BrotliEncoderInputs.text(5_000))
      {0, 1, 4, 5, 9, 10}.each do |quality|
        (10..24).each { |bits| round_trip(input, quality, bits) }
      end
    end

    it_satisfies "BROTLI-ENC-reference-files", "round-trips google/brotli's test files" do
      files = BrotliEncoderInputs.reference_files
      pending!("run conformance/brotli/fetch_testdata.rb") if files.empty?
      files.each do |name, input|
        (0..11).each do |quality|
          next if quality >= 10 && input.size > 200_000
          round_trip(input, quality, quality.even? ? 22 : 16)
        end
      end
    end

    it_satisfies "BROTLI-ENC-metablocks", "splits input larger than a metablock across several, with matches reaching back across them" do
      text = BrotliEncoderInputs.text(300_000)
      input = BrotliEncoderInputs.join(text, text, text, text)
      {1, 5}.each { |quality| round_trip(input, quality) }
    end

    it_satisfies "BROTLI-ENC-uncompressed", "stores incompressible input in uncompressed metablocks, a few bytes over its size" do
      input = BrotliEncoderInputs.random_bytes(50_000)
      {0, 5, 11}.each do |quality|
        round_trip(input, quality).size.should be <= input.size + 8
      end
    end

    it_satisfies "BROTLI-ENC-dictionary", "uses static dictionary words for short text with nothing to match" do
      input = "the information about government and development".to_slice
      round_trip(input, 11).size.should be < input.size - 10
    end

    it_satisfies "BROTLI-ENC-deterministic", "gives the same bytes for the same input and options" do
      input = BrotliEncoderInputs.html(20_000)
      (0..11).each do |quality|
        Mica::Brotli.encode(input, quality: quality).should eq(Mica::Brotli.encode(input, quality: quality))
      end
    end

    it_satisfies "BROTLI-ENC-quality-ladder", "compresses text smaller at quality 5 than at 1, and at 11 than at 5" do
      input = BrotliEncoderInputs.html(60_000)
      sizes = {1, 5, 11}.map { |quality| round_trip(input, quality).size }
      sizes[1].should be < sizes[0]
      sizes[2].should be < sizes[1]
    end

    it_satisfies "BROTLI-ENC-arguments", "raises ArgumentError for a quality outside 0 to 11 or a window outside 10 to 24" do
      {-1, 12}.each do |quality|
        expect_raises(ArgumentError, /quality/) { Mica::Brotli.encode(Bytes[1], quality: quality) }
      end
      {9, 25}.each do |bits|
        expect_raises(ArgumentError, /window_bits/) { Mica::Brotli.encode(Bytes[1], window_bits: bits) }
      end
    end
  end
end
