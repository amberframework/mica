module DeflateEncodeBench
  # Every corpus file is an asset the harness itself pinned and verified.
  MICA_LIMITS = Mica::Deflate::DecodeLimits::TRUSTED_ASSET

  # Mica's one-shot encoder: `Mica::Gzip.encode`, returning a new `Bytes`.
  class MicaOneShotEngine < Engine
    def encode(input : Bytes) : Bytes
      Mica::Gzip.encode(input, level: level)
    end

    def decode(compressed : Bytes, expected_bytes : Int32) : Bytes
      Mica::Gzip.decode(compressed, limits: MICA_LIMITS, timeout: nil)
    end
  end

  # Mica's streaming encoder: a new `Mica::Gzip::Writer` per encode, fed
  # 64 KiB pieces.
  class MicaStreamEngine < StreamingEngine
    @buffer = Bytes.new(STREAM_BUFFER_BYTES)

    def encode_stream(io : IO, sink : IO) : Nil
      writer = Mica::Gzip::Writer.new(sink, level: level)
      loop do
        read_bytes = io.read(@buffer)
        break if read_bytes == 0
        writer.write(@buffer[0, read_bytes])
      end
      writer.close
    end

    def decode(compressed : Bytes, expected_bytes : Int32) : Bytes
      Mica::Gzip.decode(compressed, limits: MICA_LIMITS, timeout: nil)
    end
  end
end
