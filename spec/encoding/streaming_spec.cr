require "./support"

private alias Codec = Mica::Encoding::Codec
private alias ErrorMode = Mica::Encoding::ErrorMode

private SEED   = ENV["MICA_ENCODING_SEED"]?.try(&.to_u64) || 20261122_u64
private ROUNDS = ENV["MICA_ENCODING_ROUNDS"]?.try(&.to_i) || 120

describe "Mica::Encoding streaming" do
  it_satisfies "ENC-STREAMING", "decodes every split of the input the same, in every encoding and error mode (seed #{SEED})" do
    random = Random::PCG32.new(SEED)
    cases = 0
    Codec.values.each do |codec|
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          input = random_encoding_bytes(random)
          whole_output, whole_error = convert_in_chunks(codec.decoder(mode), input, random, input.size * 3 + 64)
          whole_output = Bytes.new(0) unless whole_output
          chunked_output, chunked_error = convert_in_chunks(codec.decoder(mode), input, random, random.rand(16..40))
          unless chunked_output == whole_output && chunked_error.try(&.offset) == whole_error.try(&.offset) && chunked_error.try(&.problem) == whole_error.try(&.problem)
            fail "#{codec} #{mode} #{input.hexstring}: whole #{whole_output.hexstring} #{whole_error.inspect}, chunked #{chunked_output.hexstring} #{chunked_error.inspect}"
          end
          cases += 1
        end
      end
    end
    cases.should eq(Codec.values.size * ErrorMode.values.size * ROUNDS)
  end

  it_satisfies "ENC-STREAMING", "encodes every split of the input the same, in every encoding and error mode (seed #{SEED})" do
    random = Random::PCG32.new(SEED + 1)
    Codec.values.each do |codec|
      next unless codec.encodes?
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          input = random_encoding_text(random)
          whole_output, whole_error = convert_in_chunks(codec.encoder(mode), input, random, input.size * 8 + 64)
          chunked_output, chunked_error = convert_in_chunks(codec.encoder(mode), input, random, random.rand(16..40))
          unless chunked_output == whole_output && chunked_error.try(&.offset) == whole_error.try(&.offset) && chunked_error.try(&.code_point) == whole_error.try(&.code_point)
            fail "#{codec} #{mode} #{input.hexstring}: whole #{whole_output.hexstring} #{whole_error.inspect}, chunked #{chunked_output.hexstring} #{chunked_error.inspect}"
          end
        end
      end
    end
  end

  it_satisfies "ENC-OUTPUT-BOUND", "never writes more than max_decoded_size and max_encoded_size" do
    random = Random::PCG32.new(SEED + 2)
    Codec.values.each do |codec|
      ErrorMode.values.each do |mode|
        ROUNDS.times do
          input = random_encoding_bytes(random, 256)
          output, _ = convert_in_chunks(codec.decoder(mode), input, random, 64)
          output.size.should be <= codec.max_decoded_size(input.size)
          next unless codec.encodes?
          text = random_encoding_text(random, 64)
          encoded, _ = convert_in_chunks(codec.encoder(mode), text, random, 64)
          encoded.size.should be <= codec.max_encoded_size(text.size, mode)
        end
      end
    end
    # The worst cases the bounds are built on.
    Mica::Encoding.decode(Bytes.new(10, 0xFF_u8), Codec::UTF8).bytesize.should eq(30)
    Mica::Encoding.encode(Bytes.new(10, 0xFF_u8), Codec::Windows1252, ErrorMode::Replacement).size.should eq(80)
  end

  it_satisfies "ENC-ERROR-MODES", "reports the kind and offset of a fatal problem, counted over the whole stream" do
    decoder = Codec::ShiftJIS.decoder(ErrorMode::Fatal)
    output = Bytes.new(64)
    decoder.convert("ab".to_slice, output, last: false).status.should eq(Mica::Encoding::Status::InputEmpty)
    result = decoder.convert(Bytes[0x82, 0xA0, 0xFF], output, last: false)
    result.error?.should be_true
    result.problem.should eq(Mica::Encoding::Problem::InvalidSequence)
    result.offset.should eq(4)
    String.new(output[0, result.written]).should eq("あ")

    incomplete = Codec::EUCJP.decoder(ErrorMode::Fatal).convert(Bytes[0x61, 0xB0], output, last: true)
    incomplete.problem.should eq(Mica::Encoding::Problem::IncompleteSequence)
    incomplete.offset.should eq(1)

    error = expect_raises(Mica::Encoding::ConversionError) { Mica::Encoding.encode("a漢", Codec::Windows1252) }
    error.problem.should eq(Mica::Encoding::Problem::Unmappable)
    error.code_point.should eq(0x6F22)
    error.offset.should eq(1)
    error.message.should eq("windows-1252: U+6F22, a code point the encoding cannot represent at byte 1")
    Mica::Encoding.encode("a漢", Codec::Windows1252, ErrorMode::Replacement).should eq("a&#28450;".to_slice)
    Mica::Encoding.encode("a漢", Codec::Windows1252, ErrorMode::Skip).should eq("a".to_slice)
    Mica::Encoding.decode(Bytes[0x61, 0x81, 0x62], Codec::Windows1252, ErrorMode::Skip).should eq("a\u{81}b")
    Mica::Encoding.decode(Bytes[0x61, 0xFF, 0x62], Codec::UTF8, ErrorMode::Skip).should eq("ab")
  end

  it_satisfies "ENC-FATAL-RESET", "returns to the initial state after a fatal error" do
    output = Bytes.new(64)
    utf8 = Codec::UTF8.decoder(ErrorMode::Fatal, strip_bom: true)
    utf8.convert(Bytes[0xEF, 0xBB, 0xBF, 0x61, 0xE3, 0x81], output, last: false).error?.should be_false
    result = utf8.convert(Bytes[0x41], output, last: false)
    result.error?.should be_true
    result.read.should eq(0) # the byte that ended the sequence is not consumed
    # The decoder starts over: the next BOM is stripped again, no sequence is open.
    String.new(output[0, utf8.convert(Bytes[0xEF, 0xBB, 0xBF, 0x41], output, last: true).written]).should eq("A")

    jis = Codec::ISO2022JP.decoder(ErrorMode::Fatal)
    jis.convert(Bytes[0x1B, 0x24, 0x42, 0x30], output, last: false).error?.should be_false
    jis.convert(Bytes[0x1B], output, last: false).error?.should be_true
    # Back in ASCII, not in the JIS X 0208 state.
    String.new(output[0, jis.convert(Bytes[0x30, 0x21], output, last: true).written]).should eq("0!")

    encoder = Codec::ISO2022JP.encoder(ErrorMode::Fatal)
    encoder.convert("亜".to_slice, output, last: false).error?.should be_false
    encoder.convert("\u{10000}".to_slice, output, last: false).error?.should be_true
    result = encoder.convert("a".to_slice, output, last: true)
    output[0, result.written].should eq(Bytes[0x61])
  end

  it_satisfies "ENC-NO-ALLOCATION", "converts into the caller's buffers without allocating" do
    input = ("Grüße, 世界! " * 200).to_slice
    output = Bytes.new(64 * 1024)
    decoder = Codec::UTF8.decoder
    encoder = Codec::ShiftJIS.encoder
    sjis = Bytes.new(64 * 1024)
    3.times { decoder.convert(input, output, last: true) } # warm up
    before = GC.stats.total_bytes
    100.times do
      decoder.convert(input, output, last: true)
      encoder.convert("世界 abc".to_slice, sjis, last: true)
    end
    (GC.stats.total_bytes - before).should be < 1024
  end
end
