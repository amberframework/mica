# Answers conversion requests for the web-platform-tests runner
# (conformance/encoding/wpt_runner.js) with Mica::Encoding: one JSON
# request per line on standard input (or the FIFO given as the first
# argument), one JSON response per line on standard output (or the second).
#
#   crystal-alpha build --release conformance/encoding/oracle.cr -o bin/encoding_oracle
#
# Requests:
#   {"op":"label","label":"..."}                       -> {"name":"UTF-8"} or {"name":null}
#   {"op":"decode","label":"...","fatal":false,"ignore_bom":false,
#    "chunks":[{"bytes":[...],"last":false}, ...]}     -> {"results":[{"code_points":[...]} | {"error":true}]}
#   {"op":"decode_with_bom_sniff","label":"...","bytes":[...]}
#                                                      -> {"code_points":[...]}
#   {"op":"encode","label":"...","code_points":[...],"mode":"fatal|replacement"}
#                                                      -> {"bytes":[...]} or {"error":true,"code_point":N}
#   {"op":"decode_batch","label":"...","inputs":[[bytes], ...]}  -> {"outputs":[[code points], ...]} (replacement mode)
#   {"op":"encode_batch","label":"...","inputs":[[code points], ...]} -> {"outputs":[[bytes] or null, ...]} (fatal mode)
require "json"
require "../../src/mica/encoding"

module EncodingOracle
  struct Chunk
    include JSON::Serializable
    getter bytes : Array(UInt8) = [] of UInt8
    getter last : Bool = true
  end

  struct Request
    include JSON::Serializable
    getter op : String = ""
    getter label : String = ""
    getter fatal : Bool = false
    getter ignore_bom : Bool = false
    getter chunks : Array(Chunk) = [] of Chunk
    getter bytes : Array(UInt8) = [] of UInt8
    getter code_points : Array(Int32) = [] of Int32
    getter mode : String = "fatal"
    getter inputs : Array(Array(Int32)) = [] of Array(Int32)
  end

  struct DecodeResult
    include JSON::Serializable
    getter code_points : Array(Int32)?
    getter error : Bool?

    def initialize(@code_points : Array(Int32)? = nil, @error : Bool? = nil)
    end
  end

  struct Response
    include JSON::Serializable
    @[JSON::Field(emit_null: true)]
    getter name : String?
    getter results : Array(DecodeResult)?
    getter code_points : Array(Int32)?
    getter bytes : Array(UInt8)?
    getter error : Bool?
    getter code_point : Int32?
    getter message : String?
    @[JSON::Field(emit_null: true)]
    getter outputs : Array(Array(Int32)?)?

    def initialize(@name = nil, @results = nil, @code_points = nil, @bytes = nil, @error = nil, @code_point = nil, @message = nil, @outputs = nil)
    end
  end

  def self.answer(request : Request) : Response
    case request.op
    when "label"
      Response.new(name: Mica::Encoding.lookup(request.label).try(&.name))
    when "decode"
      Response.new(results: decode_chunks(request))
    when "decode_with_bom_sniff"
      Response.new(code_points: decode_with_bom_sniff(request))
    when "encode"
      encode(request)
    when "decode_batch"
      codec = Mica::Encoding.lookup!(request.label)
      Response.new(outputs: request.inputs.map { |input| Mica::Encoding.decode(Bytes.new(input.size) { |index| input[index].to_u8 }, codec).chars.map(&.ord).as(Array(Int32)?) })
    when "encode_batch"
      codec = Mica::Encoding.lookup!(request.label)
      Response.new(outputs: request.inputs.map { |input| encode_or_nil(input, codec) })
    else
      Response.new(error: true, message: "unknown op #{request.op}")
    end
  end

  # Replays every chunk of a TextDecoder's stream through one decoder and
  # returns each call's output (or the error that ended it).
  def self.decode_chunks(request : Request) : Array(DecodeResult)
    codec = Mica::Encoding.lookup!(request.label)
    mode = request.fatal ? Mica::Encoding::ErrorMode::Fatal : Mica::Encoding::ErrorMode::Replacement
    decoder = codec.decoder(mode, strip_bom: !request.ignore_bom)
    request.chunks.map do |chunk|
      begin
        DecodeResult.new(code_points: decoder.decode(Bytes.new(chunk.bytes.to_unsafe, chunk.bytes.size), chunk.last).chars.map(&.ord))
      rescue Mica::Encoding::ConversionError
        DecodeResult.new(error: true)
      end
    end
  end

  # The Encoding Standard's "decode": a byte order mark wins over the
  # label; an unknown label falls back to UTF-8 (as XMLHttpRequest does).
  def self.decode_with_bom_sniff(request : Request) : Array(Int32)
    bytes = Bytes.new(request.bytes.to_unsafe, request.bytes.size)
    codec = Mica::Encoding.lookup(request.label) || Mica::Encoding::Codec::UTF8
    if sniffed = Mica::Encoding.sniff_byte_order_mark(bytes)
      codec, length = sniffed
      bytes = bytes[length..]
    end
    Mica::Encoding.decode(bytes, codec).chars.map(&.ord)
  end

  # Encodes in fatal mode; nil when the encoder reports a problem.
  def self.encode_or_nil(code_points : Array(Int32), codec : Mica::Encoding::Codec) : Array(Int32)?
    text = String.build { |io| code_points.each { |code_point| io << code_point.chr } }
    Mica::Encoding.encode(text, codec).to_a.map(&.to_i32)
  rescue Mica::Encoding::ConversionError
    nil
  end

  def self.encode(request : Request) : Response
    codec = Mica::Encoding.lookup!(request.label)
    text = String.build { |io| request.code_points.each { |code_point| io << code_point.chr } }
    mode = request.mode == "replacement" ? Mica::Encoding::ErrorMode::Replacement : Mica::Encoding::ErrorMode::Fatal
    Response.new(bytes: Mica::Encoding.encode(text, codec, mode).to_a)
  rescue error : Mica::Encoding::ConversionError
    Response.new(error: true, code_point: error.code_point)
  end
end

input = ARGV[0]? ? File.open(ARGV[0]) : STDIN
output = ARGV[1]? ? File.open(ARGV[1], "w") : STDOUT
while line = input.gets
  response = begin
    EncodingOracle.answer(EncodingOracle::Request.from_json(line))
  rescue error
    EncodingOracle::Response.new(error: true, message: "#{error.class}: #{error.message}")
  end
  output.puts(response.to_json)
  output.flush
end
