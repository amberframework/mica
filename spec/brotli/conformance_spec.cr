require "./support/streams"

# google/brotli's conformance files (tests/testdata at v1.2.1), fetched and
# verified by conformance/brotli/fetch_testdata.rb, and the embedded
# static dictionary and transforms.
private TESTDATA = File.expand_path("../../conformance/brotli-testdata", __DIR__)

private def testdata_files : Array(String)
  return [] of String unless Dir.exists?(TESTDATA)
  Dir.children(TESTDATA).select(&.includes?(".compressed")).sort!
end

describe "Mica::Brotli conformance" do
  it_satisfies "BROTLI-7932-A-dictionary", "embeds the 122,784-byte static dictionary with its pinned CRC-32" do
    Mica::Brotli::Dictionary::DATA.size.should eq(122_784)
    # CRC-32 of google/brotli v1.2.1 c/common/dictionary.bin (sha256
    # 20e42eb1…5c70, checked by conformance/brotli/fetch_testdata.rb).
    Mica::Deflate::CRC32.update(0_u32, Mica::Brotli::Dictionary::DATA).should eq(0x5136cb04_u32)
    # Each length's words end where the next length's begin.
    (4..23).each do |length|
      span = (1 << Mica::Brotli::Dictionary::SIZE_BITS_BY_LENGTH[length]) * length
      (Mica::Brotli::Dictionary::OFFSETS_BY_LENGTH[length] + span).should eq(Mica::Brotli::Dictionary::OFFSETS_BY_LENGTH[length + 1])
    end
  end

  it_satisfies "BROTLI-7932-B-transforms", "has the 121 transforms of Appendix B" do
    transforms = Mica::Brotli::Tables::TRANSFORMS
    transforms.size.should eq(121)
    transforms[0].should eq(Mica::Brotli::Tables::Transform.new(Bytes.empty, 0_u8, Bytes.empty))
    transforms[5].suffix.should eq(" the ".to_slice)
    transforms[120].prefix.should eq(" ".to_slice)
    transforms[120].kind.should eq(10_u8)
    transforms[120].suffix.should eq("='".to_slice)
    Mica::Brotli::Tables::CONTEXT_LOOKUP.size.should eq(2048)
  end

  it_satisfies "BROTLI-CONFORMANCE-testdata", "decodes every google/brotli v1.2.1 test file byte for byte, one-shot and streaming" do
    files = testdata_files
    if files.empty?
      pending!("run /usr/bin/ruby conformance/brotli/fetch_testdata.rb to fetch the test files")
    end
    files.size.should eq(45)
    files.each do |name|
      compressed = File.read(File.join(TESTDATA, name)).to_slice
      expected = File.read(File.join(TESTDATA, name.sub(/\.compressed.*\z/, ""))).to_slice
      Mica::Brotli.decode(compressed, limits: BrotliStreams::LIMITS, timeout: nil).should eq(expected)
      reader = Mica::Brotli::Reader.new(IO::Memory.new(compressed, false), limits: BrotliStreams::LIMITS, timeout: nil)
      reader.gets_to_end.to_slice.should eq(expected)
    end
  end
end
