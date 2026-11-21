require "./lib_system_z"

module DeflateBench
  # System zlib, one call: `inflate(Z_FINISH)` over the whole input into a
  # buffer of the known output size.
  abstract class ZlibOneShotEngine < Engine
    # The buffer one decode writes into.
    abstract def output_buffer : Bytes

    def decode(compressed : Bytes) : Bytes
      output = output_buffer
      stream = LibSystemZ::Stream.new
      SystemZ.start_inflate(pointerof(stream), format)
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
  end

  # The baseline Mica's one-shot decode is paired with: every decode
  # allocates its own output buffer from the collector, untouched (not
  # zeroed), as a caller that keeps the result must, and as Mica's one-shot
  # API does.
  class ZlibOneShotFreshBufferEngine < ZlibOneShotEngine
    def output_buffer : Bytes
      Bytes.new(GC.malloc_atomic(expected_bytes.to_u64).as(UInt8*), expected_bytes)
    end
  end

  # zlib's best case: one output buffer allocated when the process starts
  # and written again by every decode.
  class ZlibOneShotReusedBufferEngine < ZlibOneShotEngine
    @output : Bytes

    def initialize(format : Format, expected_bytes : Int64)
      super
      @output = Bytes.new(expected_bytes)
    end

    def output_buffer : Bytes
      @output
    end
  end

  # System zlib, streaming: `inflate(Z_NO_FLUSH)` with a 64 KiB input buffer
  # filled from the IO and a 64 KiB output buffer.
  class ZlibStreamEngine < StreamingEngine
    @input_buffer = Bytes.new(STREAM_BUFFER_BYTES)
    @output_buffer = Bytes.new(STREAM_BUFFER_BYTES)

    def each_decoded_chunk(io : IO, & : Bytes ->) : Nil
      stream = LibSystemZ::Stream.new
      SystemZ.start_inflate(pointerof(stream), format)
      begin
        loop do
          if stream.avail_in == 0
            read_bytes = io.read(@input_buffer)
            raise ZlibError.new("the input ended inside the stream") if read_bytes == 0
            stream.next_in = @input_buffer.to_unsafe
            stream.avail_in = read_bytes.to_u32
          end
          stream.next_out = @output_buffer.to_unsafe
          stream.avail_out = @output_buffer.size.to_u32
          status = LibSystemZ.inflate(pointerof(stream), SystemZ::NO_FLUSH)
          produced_bytes = @output_buffer.size - stream.avail_out
          yield @output_buffer[0, produced_bytes] if produced_bytes > 0
          break if status == SystemZ::STREAM_END
          unless status == SystemZ::OK || status == SystemZ::BUFFER_ERROR
            raise ZlibError.new("inflate returned #{status}")
          end
        end
      ensure
        LibSystemZ.inflateEnd(pointerof(stream))
      end
    end
  end
end
