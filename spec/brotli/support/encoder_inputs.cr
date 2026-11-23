require "./streams"

# Inputs for the encoder specs: the shapes a server compresses.
module BrotliEncoderInputs
  TESTDATA = File.expand_path("../../../conformance/brotli-testdata", __DIR__)

  def self.decode(bytes : Bytes) : Bytes
    Mica::Brotli.decode(bytes, limits: BrotliStreams::LIMITS, timeout: nil)
  end

  def self.text(size : Int32) : Bytes
    words = %w(the quick brown fox jumps over a lazy dog while Brotli encodes every sentence it is given again)
    random = Random.new(5)
    text = String.build do |io|
      while io.bytesize < size
        io << words[random.rand(words.size)] << (random.rand(9) == 0 ? ".\n" : " ")
      end
    end
    text.to_slice[0, size]
  end

  def self.json(size : Int32) : Bytes
    random = Random.new(6)
    String.build do |io|
      io << "["
      index = 0
      while io.bytesize < size
        io << "," if index > 0
        io << %({"id":) << index << %(,"name":"user) << random.rand(1000) << %(","active":) << (random.rand(2) == 0) << %(,"score":) << random.rand(100_000) << "}"
        index += 1
      end
      io << "]"
    end.to_slice
  end

  def self.html(size : Int32) : Bytes
    random = Random.new(7)
    String.build do |io|
      io << "<!doctype html><html><head><title>Page</title></head><body>\n"
      while io.bytesize < size
        io << %(<div class="card"><a href="/items/) << random.rand(10_000) << %(">Item ) << random.rand(500) << "</a><p>" << String.new(text(random.rand(20..120))) << "</p></div>\n"
      end
      io << "</body></html>\n"
    end.to_slice
  end

  def self.join(*parts : Bytes) : Bytes
    io = IO::Memory.new
    parts.each { |part| io.write(part) }
    io.to_slice
  end

  def self.random_bytes(size : Int32) : Bytes
    random = Random.new(8)
    Bytes.new(size) { random.rand(256).to_u8 }
  end

  # The named inputs every quality and window is checked on.
  def self.all : Array({String, Bytes})
    list = [
      {"empty", Bytes.empty},
      {"one byte", Bytes[42]},
      {"all zero", Bytes.new(70_000, 0_u8)},
      {"random", random_bytes(20_000)},
      {"text", text(40_000)},
      {"json", json(30_000)},
      {"html", html(30_000)},
    ]
    list
  end

  # google/brotli v1.2.1 test files (the originals, not the .compressed
  # streams), when conformance/brotli/fetch_testdata.rb has fetched them.
  def self.reference_files : Array({String, Bytes})
    return [] of {String, Bytes} unless Dir.exists?(TESTDATA)
    Dir.children(TESTDATA).reject(&.includes?(".compressed")).sort!.map do |name|
      {name, File.read(File.join(TESTDATA, name)).to_slice}
    end
  end
end
