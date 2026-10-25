# Extracts the urlencoded parser vectors from web-platform-tests
# `url/urlencoded-parser.any.js` into the JSON fixture that
# conformance/form/run.cr and spec/form/wpt_spec.cr read.
#
#   curl -sSfL -o /tmp/urlencoded-parser.any.js \
#     https://raw.githubusercontent.com/web-platform-tests/wpt/b0099c748bac89b857e77ba9e132123b7db61693/url/urlencoded-parser.any.js
#   crystal-alpha run conformance/form/extract_wpt.cr -- /tmp/urlencoded-parser.any.js > conformance/form/wpt_urlencoded.json
#
# The source is pinned by commit and sha256; a file with another hash is
# refused, so the fixture can only be regenerated from the reviewed bytes.
require "digest/sha256"
require "json"

WPT_COMMIT = "b0099c748bac89b857e77ba9e132123b7db61693"
WPT_PATH   = "url/urlencoded-parser.any.js"
WPT_SHA256 = "9d3514f33a6bce8ab4d0163a77d79f0231ef30239ca237cf75f9e206a8b0c3e8"

# Reads the array literal at the top of the file: objects with an
# "input" string and an "output" array of [name, value] string pairs.
class VectorScanner
  record Vector, input : String, output : Array({String, String})

  def initialize(@text : String)
    @reader = Char::Reader.new(@text)
  end

  def vectors : Array(Vector)
    list_of_vectors = [] of Vector
    expect('[')
    loop do
      skip_space
      break if @reader.current_char == ']'
      list_of_vectors << vector
      skip_space
      @reader.next_char if @reader.current_char == ','
    end
    list_of_vectors
  end

  private def vector : Vector
    expect('{')
    input = ""
    output = [] of {String, String}
    loop do
      skip_space
      break if @reader.current_char == '}'
      key = string
      expect(':')
      if key == "input"
        input = string
      else
        output = pairs
      end
      skip_space
      @reader.next_char if @reader.current_char == ','
    end
    @reader.next_char
    Vector.new(input, output)
  end

  private def pairs : Array({String, String})
    list_of_pairs = [] of {String, String}
    expect('[')
    loop do
      skip_space
      break if @reader.current_char == ']'
      expect('[')
      name = string
      expect(',')
      value = string
      expect(']')
      list_of_pairs << {name, value}
      skip_space
      @reader.next_char if @reader.current_char == ','
    end
    @reader.next_char
    list_of_pairs
  end

  private def string : String
    skip_space
    quote = @reader.current_char
    raise "Expected a string at #{@reader.pos}" unless quote == '"' || quote == '\''
    @reader.next_char
    String.build do |io|
      until @reader.current_char == quote
        char = @reader.current_char
        if char == '\\'
          io << escape
        else
          io << char
          @reader.next_char
        end
      end
      @reader.next_char
    end
  end

  private def escape : Char
    @reader.next_char
    char = @reader.current_char
    @reader.next_char
    case char
    when 'u'
      hex = String.build { |io| 4.times { io << @reader.current_char; @reader.next_char } }
      hex.to_i(16).chr
    when '0' then '\0'
    when 'n' then '\n'
    when 'r' then '\r'
    else          char
    end
  end

  private def expect(char : Char) : Nil
    skip_space
    raise "Expected #{char.inspect} at #{@reader.pos}" unless @reader.current_char == char
    @reader.next_char
  end

  private def skip_space : Nil
    while @reader.current_char.whitespace?
      @reader.next_char
    end
  end
end

path = ARGV[0]? || abort("usage: extract_wpt PATH_TO_urlencoded-parser.any.js")
text = File.read(path)
digest = Digest::SHA256.hexdigest(text)
abort("#{path}: sha256 #{digest} does not match the pinned #{WPT_SHA256}") unless digest == WPT_SHA256

JSON.build(STDOUT, indent: 2) do |json|
  json.object do
    json.field "source", "https://github.com/web-platform-tests/wpt/blob/#{WPT_COMMIT}/#{WPT_PATH}"
    json.field "sha256", WPT_SHA256
    json.field "vectors" do
      json.array do
        VectorScanner.new(text).vectors.each do |vector|
          json.object do
            json.field "input", vector.input
            json.field "output" do
              json.array do
                vector.output.each { |name, value| json.array { json.string name; json.string value } }
              end
            end
          end
        end
      end
    end
  end
end
STDOUT.puts
