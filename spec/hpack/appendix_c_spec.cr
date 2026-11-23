require "./support"
require "./fixtures/appendix_c"

private def encoder_for(group : String) : Mica::HPACK::Encoder
  # The examples index cookies and credentials, so the encoder that
  # reproduces them is given no never-indexed names.
  huffman = group.starts_with?("C.4") || group.starts_with?("C.6")
  max_table_size = group.starts_with?("C.5") || group.starts_with?("C.6") ? 256 : Mica::HPACK::DEFAULT_TABLE_SIZE
  max_table_size = 0 if group == "C.2.2"
  Mica::HPACK::Encoder.new(max_table_size: max_table_size, huffman: huffman, never_indexed_names: [] of String)
end

describe "Mica::HPACK and RFC 7541 Appendix C" do
  it_satisfies "HPACK-7541-appendix-c", "decodes every example of C.2 to C.6 to its headers and table size" do
    AppendixC::EXAMPLES.size.should eq 16
    decoders = {} of String => Mica::HPACK::Decoder
    AppendixC::EXAMPLES.each do |example|
      group = example.id.starts_with?("C.2") ? example.id : example.id[0, 3]
      # C.5 and C.6 start with SETTINGS_HEADER_TABLE_SIZE at 256.
      max_table_size = group.starts_with?("C.5") || group.starts_with?("C.6") ? 256 : 4_096
      decoder = decoders[group] ||= Mica::HPACK::Decoder.new(limits: Mica::HPACK::DecodeLimits::PUBLIC_SERVER, max_table_size: max_table_size)
      HPACKSpec.fields(decoder.decode(HPACKSpec.hex(example.hex))).should eq example.headers
      decoder.table_size.should eq example.table_size
    end
  end

  it_satisfies "HPACK-7541-appendix-c", "reproduces the bytes of every example of C.2 to C.6" do
    encoders = {} of String => Mica::HPACK::Encoder
    AppendixC::EXAMPLES.each do |example|
      group = example.id.starts_with?("C.2") ? example.id : example.id[0, 3]
      encoder = encoders[group] ||= encoder_for(group)
      list = HPACKSpec.headers(example.headers)
      list = list.map(&.copy_with(never_indexed: true)) if example.id == "C.2.3"
      encoder.encode(list).hexstring.should eq example.hex
      encoder.table_size.should eq example.table_size
    end
  end

  it_satisfies({"HPACK-7541-6.1-indexed", "HPACK-7541-6.2.1-incremental-indexing", "HPACK-7541-6.2.2-without-indexing",
                "HPACK-7541-6.2.3-never-indexed", "HPACK-7541-4.1-entry-size"}, "applies each representation of C.2 to the table") do
    decoder = HPACKSpec.decoder
    decoder.decode(HPACKSpec.hex("400a637573746f6d2d6b65790d637573746f6d2d686561646572")).should eq [
      Mica::HPACK::Header.new("custom-key", "custom-header"),
    ]
    decoder.table_length.should eq 1
    decoder.table_size.should eq 10 + 13 + 32
    decoder.decode(HPACKSpec.hex("040c2f73616d706c652f70617468")).should eq [Mica::HPACK::Header.new(":path", "/sample/path")]
    decoder.table_length.should eq 1
    decoder.decode(HPACKSpec.hex("100870617373776f726406736563726574")).should eq [
      Mica::HPACK::Header.new("password", "secret", never_indexed: true),
    ]
    decoder.table_length.should eq 1
    decoder.decode(Bytes[0x82, 0xbe]).should eq [
      Mica::HPACK::Header.new(":method", "GET"), Mica::HPACK::Header.new("custom-key", "custom-header"),
    ]
  end
end
