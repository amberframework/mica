require "./support"
require "./sha256"

# The http2jp/hpack-test-case corpus, when conformance/hpack/fetch_test_case.rb
# has fetched it (CI fetches it before the specs run). The pin is recorded in
# spec/vectors/hpack/SOURCES.md.
private COMMIT         = "8a1406e7d14bfcb6c046021f13cc15cfb162726d"
private ARCHIVE_SHA256 = "53355bf708fb890a235b3a679061d116a020818e92caaadbc243f9c91c4c48eb"
private ROOT           = File.join(__DIR__, "..", "..", "conformance", "hpack-test-case")
private ARCHIVE        = File.join(ROOT, "hpack-test-case-#{COMMIT}.tar.gz")
private DATA           = File.join(ROOT, "data")

private def list_of_story_paths(directory : String) : Array(String)
  Dir.glob(File.join(DATA, directory, "story_*.json")).sort!
end

private def list_of_implementations : Array(String)
  Dir.children(DATA).select { |name| name != "raw-data" && !list_of_story_paths(name).empty? }.sort!
end

describe "Mica::HPACK and http2jp/hpack-test-case" do
  if File.exists?(ARCHIVE)
    it_satisfies "HPACK-TEST-CASE", "decodes every story of every implementation directory at #{COMMIT[0, 7]}" do
      SpecSHA256.hexdigest(File.read(ARCHIVE).to_slice).should eq ARCHIVE_SHA256
      implementations = list_of_implementations
      implementations.size.should eq 14
      stories = 0
      cases = 0
      list_of_failures = [] of String
      implementations.each do |implementation|
        list_of_story_paths(implementation).each do |path|
          stories += 1
          story = HPACKSpec::Story.from_json(File.read(path))
          decoder = HPACKSpec.decoder(HPACKSpec::CORPUS_LIMITS)
          story.cases.each do |kase|
            cases += 1
            if size = kase.header_table_size
              decoder.max_table_size = size
            end
            begin
              decoded = HPACKSpec.fields(decoder.decode(kase.wire.hexbytes))
              list_of_failures << "#{implementation}/#{File.basename(path)} case #{kase.seqno}" unless decoded == kase.list_of_fields
            rescue error : Mica::Error
              list_of_failures << "#{implementation}/#{File.basename(path)} case #{kase.seqno}: #{error.message}"
              break
            end
          end
        end
      end
      list_of_failures.should eq [] of String
      stories.should eq 446
      cases.should eq 47_142
    end

    it_satisfies "HPACK-ENCODER-ROUND-TRIP", "encodes every raw-data story into blocks that decode to it" do
      list_of_story_paths("raw-data").size.should eq 32
      {true, false}.each do |huffman|
        list_of_story_paths("raw-data").each do |path|
          story = HPACKSpec::Story.from_json(File.read(path))
          encoder = Mica::HPACK::Encoder.new(huffman: huffman)
          decoder = HPACKSpec.decoder(HPACKSpec::CORPUS_LIMITS)
          story.cases.each do |kase|
            fields = kase.list_of_fields
            HPACKSpec.fields(decoder.decode(encoder.encode(HPACKSpec.headers(fields)))).should eq fields
          end
        end
      end
    end
  else
    it_satisfies({"HPACK-TEST-CASE", "HPACK-ENCODER-ROUND-TRIP"}, "decodes the first case of nghttp2/story_00.json, kept in this spec") do
      # The fetched corpus is not here (run conformance/hpack/fetch_test_case.rb
      # for all 446 stories).
      HPACKSpec.fields(HPACKSpec.decoder.decode("82864188f439ce75c875fa5784".hexbytes)).should eq [
        {":method", "GET"}, {":scheme", "http"}, {":authority", "yahoo.co.jp"}, {":path", "/"},
      ]
    end
  end
end
