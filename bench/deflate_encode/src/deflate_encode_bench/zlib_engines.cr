require "../../../deflate/src/deflate_bench/format"
require "../../../deflate/src/deflate_bench/lib_system_z"

module DeflateEncodeBench
  alias SystemZ = DeflateBench::SystemZ

  # Starts a deflate on *stream* where it lives (zlib keeps the stream's
  # address in its state): gzip container, 32 KiB window, zlib's default
  # memory level and strategy.
  def self.start_deflate(stream : LibSystemZ::Stream*, level : Int32) : Nil
    SystemZ.check LibSystemZ.deflateInit2_(stream, level, SystemZ::DEFLATED, GZIP_WINDOW_BITS, SystemZ::MEMORY_LEVEL,
      SystemZ::DEFAULT_STRATEGY, LibSystemZ.zlibVersion, sizeof(LibSystemZ::Stream)), "deflateInit2"
  end

  # Decodes a gzip member with system zlib's inflate.
  def self.inflate_with_system_zlib(compressed : Bytes, expected_bytes : Int32) : Bytes
    output = Bytes.new(expected_bytes + 1)
    stream = LibSystemZ::Stream.new
    SystemZ.check LibSystemZ.inflateInit2_(pointerof(stream), GZIP_WINDOW_BITS, LibSystemZ.zlibVersion,
      sizeof(LibSystemZ::Stream)), "inflateInit2"
    stream.next_in = compressed.to_unsafe
    stream.avail_in = compressed.size.to_u32
    stream.next_out = output.to_unsafe
    stream.avail_out = output.size.to_u32
    status = LibSystemZ.inflate(pointerof(stream), SystemZ::FINISH)
    decoded_bytes = stream.total_out
    unread_bytes = stream.avail_in
    LibSystemZ.inflateEnd(pointerof(stream))
    unless status == SystemZ::STREAM_END && unread_bytes == 0
      raise ZlibError.new("inflate returned #{status} with #{unread_bytes} input bytes unread")
    end
    output[0, decoded_bytes]
  end

  # System zlib, one call: `deflateInit2`, `deflate(Z_FINISH)` over the
  # whole input into a buffer of `deflateBound` bytes allocated for this
  # encode from the collector, untouched (not zeroed), and `deflateEnd`:
  # what a caller that keeps the result does, and what Mica's one-shot API
  # does.
  class ZlibOneShotEngine < Engine
    def encode(input : Bytes) : Bytes
      stream = LibSystemZ::Stream.new
      DeflateEncodeBench.start_deflate(pointerof(stream), level)
      bound = LibSystemZ.deflateBound(pointerof(stream), input.size)
      output = Bytes.new(GC.malloc_atomic(bound).as(UInt8*), bound)
      stream.next_in = input.to_unsafe
      stream.avail_in = input.size.to_u32
      stream.next_out = output.to_unsafe
      stream.avail_out = output.size.to_u32
      status = LibSystemZ.deflate(pointerof(stream), SystemZ::FINISH)
      compressed_bytes = stream.total_out
      LibSystemZ.deflateEnd(pointerof(stream))
      raise ZlibError.new("deflate returned #{status}") unless status == SystemZ::STREAM_END
      output[0, compressed_bytes]
    end

    def decode(compressed : Bytes, expected_bytes : Int32) : Bytes
      DeflateEncodeBench.inflate_with_system_zlib(compressed, expected_bytes)
    end
  end

  # System zlib, streaming: a new stream per encode, `deflate(Z_NO_FLUSH)`
  # on 64 KiB pieces of input into a 64 KiB output buffer, then
  # `deflate(Z_FINISH)`.
  class ZlibStreamEngine < StreamingEngine
    @input_buffer = Bytes.new(STREAM_BUFFER_BYTES)
    @output_buffer = Bytes.new(STREAM_BUFFER_BYTES)

    def encode_stream(io : IO, sink : IO) : Nil
      stream = LibSystemZ::Stream.new
      DeflateEncodeBench.start_deflate(pointerof(stream), level)
      begin
        loop do
          read_bytes = io.read(@input_buffer)
          flush = read_bytes == 0 ? SystemZ::FINISH : SystemZ::NO_FLUSH
          stream.next_in = @input_buffer.to_unsafe
          stream.avail_in = read_bytes.to_u32
          status = SystemZ::OK
          loop do
            stream.next_out = @output_buffer.to_unsafe
            stream.avail_out = @output_buffer.size.to_u32
            status = LibSystemZ.deflate(pointerof(stream), flush)
            unless status == SystemZ::OK || status == SystemZ::STREAM_END || status == SystemZ::BUFFER_ERROR
              raise ZlibError.new("deflate returned #{status}")
            end
            produced_bytes = @output_buffer.size - stream.avail_out
            sink.write(@output_buffer[0, produced_bytes]) if produced_bytes > 0
            # A full output buffer means zlib may hold more.
            break unless stream.avail_out == 0
          end
          break if status == SystemZ::STREAM_END
        end
      ensure
        LibSystemZ.deflateEnd(pointerof(stream))
      end
    end

    def decode(compressed : Bytes, expected_bytes : Int32) : Bytes
      DeflateEncodeBench.inflate_with_system_zlib(compressed, expected_bytes)
    end
  end
end
