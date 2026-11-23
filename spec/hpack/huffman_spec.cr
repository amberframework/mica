require "./support"

private def huffman(text : Bytes) : Bytes
  io = IO::Memory.new
  Mica::HPACK::Huffman.encode(text, io)
  io.to_slice
end

private def unhuffman(coded : Bytes) : Bytes?
  output = Bytes.new(coded.size * 8 // 5 + 1)
  written = Mica::HPACK::Huffman.decode(coded, output.to_unsafe)
  written < 0 ? nil : output[0, written]
end

# A literal (without indexing, new name "x") whose value is the Huffman
# string *coded*.
private def block_with_huffman_value(coded : Bytes) : Bytes
  io = IO::Memory.new
  io.write(Bytes[0x00, 0x01, 'x'.ord.to_u8])
  Mica::HPACK::PrefixInteger.encode(io, 0x80_u8, 7, coded.size.to_i64)
  io.write(coded)
  io.to_slice
end

describe Mica::HPACK::Huffman do
  it_satisfies "HPACK-7541-appendix-b-huffman", "codes and decodes every octet alone and in random strings" do
    256.times do |octet|
      text = Bytes[octet.to_u8]
      coded = huffman(text)
      coded.size.should eq Mica::HPACK::Huffman.encoded_size(text)
      unhuffman(coded).should eq text
    end
    random = Random.new(7541)
    2_000.times do
      text = Bytes.new(random.rand(0..200)) { random.rand(256).to_u8 }
      unhuffman(huffman(text)).should eq text
    end
  end

  it_satisfies "HPACK-7541-appendix-b-huffman", "gives the RFC 7541 code lengths: 5 bits for '0', 30 for EOS" do
    Mica::HPACK::Huffman::LENGTHS['0'.ord].should eq 5
    Mica::HPACK::Huffman::CODES['0'.ord].should eq 0x0_u32
    Mica::HPACK::Huffman::LENGTHS[256].should eq 30
    Mica::HPACK::Huffman::CODES[256].should eq 0x3fffffff_u32
    huffman("www.example.com".to_slice).hexstring.should eq "f1e3c2e5f23a6ba0ab90f4ff"
  end

  it_satisfies "HPACK-7541-5.2-huffman-eos", "rejects a string that contains the EOS code" do
    # EOS (30 one bits) padded with two more ones: 0xff 0xff 0xff 0xff.
    unhuffman(Bytes[0xff, 0xff, 0xff, 0xff]).should be_nil
    # 'a' (00011, 5 bits) then EOS: 00011111 11111111 11111111 11111111 111(pad 1).
    unhuffman(Bytes[0x1f, 0xff, 0xff, 0xff, 0xff]).should be_nil
    expect_raises(Mica::HPACK::HuffmanError) do
      HPACKSpec.decoder.decode(block_with_huffman_value(Bytes[0xff, 0xff, 0xff, 0xff]))
    end
  end

  it_satisfies "HPACK-7541-5.2-huffman-padding", "rejects padding over 7 bits and padding that is not all ones" do
    # '0' is 00000; a whole byte of ones after it is 8 bits of padding.
    unhuffman(Bytes[0x07]).should eq "0".to_slice
    unhuffman(Bytes[0x07, 0xff]).should be_nil
    # '0' padded with 011 instead of 111.
    unhuffman(Bytes[0x03]).should be_nil
    # A lone byte of ones is 8 bits of padding (no symbol).
    unhuffman(Bytes[0xff]).should be_nil
    unhuffman(Bytes.empty).should eq Bytes.empty
    expect_raises(Mica::HPACK::HuffmanError) { HPACKSpec.decoder.decode(block_with_huffman_value(Bytes[0x07, 0xff])) }
    expect_raises(Mica::HPACK::HuffmanError) { HPACKSpec.decoder.decode(block_with_huffman_value(Bytes[0x03])) }
  end
end
