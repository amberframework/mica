module DeflateBench
  # Every corpus file is an asset the harness itself pinned and verified.
  MICA_LIMITS = Mica::Deflate::DecodeLimits::TRUSTED_ASSET

  # Mica's one-shot decoders: `Mica::Gzip.decode`, `Mica::Zlib.decode` and
  # `Mica::Deflate.decode`, each returning a new `Bytes`.
  class MicaOneShotEngine < Engine
    def decode(compressed : Bytes) : Bytes
      case format
      in .gzip?    then Mica::Gzip.decode(compressed, limits: MICA_LIMITS, timeout: nil)
      in .zlib?    then Mica::Zlib.decode(compressed, limits: MICA_LIMITS, timeout: nil)
      in .deflate? then Mica::Deflate.decode(compressed, limits: MICA_LIMITS, timeout: nil)
      end
    end
  end

  # Mica's streaming readers (`Mica::Gzip::Reader` and its zlib and raw
  # DEFLATE siblings), read through a 64 KiB slice.
  class MicaStreamEngine < StreamingEngine
    @buffer = Bytes.new(STREAM_BUFFER_BYTES)

    def each_decoded_chunk(io : IO, & : Bytes ->) : Nil
      reader = reader_over(io)
      loop do
        read_bytes = reader.read(@buffer)
        break if read_bytes == 0
        yield @buffer[0, read_bytes]
      end
      reader.close
    end

    private def reader_over(io : IO) : IO
      case format
      in .gzip?    then Mica::Gzip::Reader.new(io, limits: MICA_LIMITS, timeout: nil)
      in .zlib?    then Mica::Zlib::Reader.new(io, limits: MICA_LIMITS, timeout: nil)
      in .deflate? then Mica::Deflate::Reader.new(io, limits: MICA_LIMITS, timeout: nil)
      end
    end
  end
end
