require "digest/sha256"

module DeflateEncodeBench
  # Streaming engines take their input and hand out their output through
  # buffers of this size.
  STREAM_BUFFER_BYTES = 65_536

  # Every engine writes one gzip member (RFC 1952), the container Amber
  # sends as `Content-Encoding: gzip`: zlib's windowBits 31.
  GZIP_WINDOW_BITS = 31

  alias Error = DeflateBench::Error
  alias UsageError = DeflateBench::UsageError
  alias OutputMismatchError = DeflateBench::OutputMismatchError
  alias ZlibError = DeflateBench::ZlibError

  # One way of compressing a case. An engine is built once per runner
  # process for the case's level, then compresses the same input for every
  # timed sample.
  abstract class Engine
    getter level : Int32

    def initialize(@level : Int32)
    end

    # Compresses *input* into one gzip member and returns it. The returned
    # slice is only read until the next call (an engine may reuse its
    # buffer).
    abstract def encode(input : Bytes) : Bytes

    # Decodes *compressed* with the engine's own library, for the check
    # that follows every timed batch.
    abstract def decode(compressed : Bytes, expected_bytes : Int32) : Bytes

    # Compresses the file at *path* once for the peak-memory process and
    # returns the compressed size. One-shot engines hold the whole input
    # and the whole output, as their callers do.
    def encode_file(path : String) : Int64
      encode(File.open(path, &.getb_to_end)).size.to_i64
    end
  end

  # Collects a stream in one buffer allocated when the process starts.
  class BufferSink < IO
    getter written : Int32 = 0

    def initialize(@buffer : Bytes)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("write-only")
    end

    def write(slice : Bytes) : Nil
      if @written + slice.size > @buffer.size
        raise OutputMismatchError.new("the stream passes the #{@buffer.size} bytes set aside for it")
      end
      slice.copy_to(@buffer.to_unsafe + @written, slice.size)
      @written += slice.size
    end
  end

  # Counts a stream's bytes and keeps none.
  class CountingSink < IO
    getter written : Int64 = 0_i64

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("write-only")
    end

    def write(slice : Bytes) : Nil
      @written += slice.size
    end
  end

  # An engine that takes the input in pieces of `STREAM_BUFFER_BYTES` and
  # writes compressed chunks to a sink as they are produced.
  abstract class StreamingEngine < Engine
    @output : Bytes?

    # Reads *io* to its end in 64 KiB pieces and writes every chunk of
    # compressed output to *sink*.
    abstract def encode_stream(io : IO, sink : IO) : Nil

    # Timed encodes collect every chunk in one buffer that holds the
    # largest stream the input can become, so the bytes can be checked
    # after the clock stops. Every streaming engine pays the same copy.
    def encode(input : Bytes) : Bytes
      output = @output ||= Bytes.new(input.size + input.size // 1_000 + 1_024)
      sink = BufferSink.new(output)
      encode_stream(IO::Memory.new(input, writable: false), sink)
      output[0, sink.written]
    end

    # The peak-memory encode streams from the file and counts the output,
    # so neither the whole input nor the whole output is held.
    def encode_file(path : String) : Int64
      sink = CountingSink.new
      File.open(path) { |file| encode_stream(file, sink) }
      sink.written
    end
  end
end
