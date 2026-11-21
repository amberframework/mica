# The harness's own binding to the system zlib (/usr/lib/libz.1.dylib on
# macOS), independent of the stdlib's `LibZ`, so the baseline calls zlib's
# inflate directly.
@[Link("z")]
lib LibSystemZ
  alias AllocFunction = (Void*, UInt32, UInt32) -> Void*
  alias FreeFunction = (Void*, Void*) -> Void

  struct Stream
    next_in : UInt8*
    avail_in : UInt32
    total_in : LibC::ULong
    next_out : UInt8*
    avail_out : UInt32
    total_out : LibC::ULong
    msg : LibC::Char*
    state : Void*
    zalloc : AllocFunction
    zfree : FreeFunction
    opaque : Void*
    data_type : LibC::Int
    adler : LibC::ULong
    reserved : LibC::ULong
  end

  fun zlibVersion : LibC::Char*
  fun inflateInit2_(stream : Stream*, window_bits : LibC::Int, version : LibC::Char*, stream_size : LibC::Int) : LibC::Int
  fun inflate(stream : Stream*, flush : LibC::Int) : LibC::Int
  fun inflateEnd(stream : Stream*) : LibC::Int
  fun deflateInit2_(stream : Stream*, level : LibC::Int, method : LibC::Int, window_bits : LibC::Int,
                    memory_level : LibC::Int, strategy : LibC::Int, version : LibC::Char*,
                    stream_size : LibC::Int) : LibC::Int
  fun deflateBound(stream : Stream*, source_bytes : LibC::ULong) : LibC::ULong
  fun deflate(stream : Stream*, flush : LibC::Int) : LibC::Int
  fun deflateEnd(stream : Stream*) : LibC::Int
end

module DeflateBench
  module SystemZ
    OK               =  0
    STREAM_END       =  1
    BUFFER_ERROR     = -5
    NO_FLUSH         =  0
    FINISH           =  4
    DEFLATED         =  8
    DEFAULT_STRATEGY =  0
    MEMORY_LEVEL     =  8

    def self.version : String
      String.new(LibSystemZ.zlibVersion)
    end

    def self.check(status : Int32, call : String) : Nil
      raise ZlibError.new("#{call} returned #{status}") unless status == OK
    end

    # Starts an inflate on *stream* where it lives: zlib keeps the stream's
    # address in its state and rejects a stream that has been copied.
    def self.start_inflate(stream : LibSystemZ::Stream*, format : Format) : Nil
      check LibSystemZ.inflateInit2_(stream, format.window_bits, LibSystemZ.zlibVersion,
        sizeof(LibSystemZ::Stream)), "inflateInit2"
    end
  end
end
