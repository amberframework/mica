require "digest/sha256"

module DeflateBench
  # Streaming engines read their input and hand out their output through
  # buffers of this size.
  STREAM_BUFFER_BYTES = 65_536

  # One way of decoding a case. An engine is built once per runner process
  # for the case's format and known output size, then decodes the same
  # compressed bytes for every timed sample.
  abstract class Engine
    getter format : Format
    getter expected_bytes : Int64

    def initialize(@format : Format, @expected_bytes : Int64)
    end

    # Decodes *compressed* and returns the decoded bytes. The returned slice
    # is only read until the next call (an engine may reuse its buffer).
    abstract def decode(compressed : Bytes) : Bytes

    # Decodes the file at *path* once for the peak-memory process and
    # returns the output's size and sha256. One-shot engines hold the whole
    # input and the whole output, as their callers do.
    def decode_file(path : String) : {Int64, String}
      output = decode(File.open(path, &.getb_to_end))
      {output.size.to_i64, Digest::SHA256.hexdigest(output)}
    end
  end

  # An engine that pulls compressed bytes from an IO and yields decoded
  # chunks of at most `STREAM_BUFFER_BYTES`.
  abstract class StreamingEngine < Engine
    @output : Bytes?

    abstract def each_decoded_chunk(io : IO, & : Bytes ->) : Nil

    # Timed decodes copy every chunk into one buffer sized from the known
    # output, so the bytes can be hashed after the clock stops. Every
    # streaming engine pays the same copy.
    def decode(compressed : Bytes) : Bytes
      output = @output ||= Bytes.new(expected_bytes)
      written = 0
      each_decoded_chunk(IO::Memory.new(compressed, writable: false)) do |chunk|
        if written + chunk.size > output.size
          raise OutputMismatchError.new("decoded more than the expected #{expected_bytes} bytes")
        end
        chunk.copy_to(output + written)
        written += chunk.size
      end
      output[0, written]
    end

    # The peak-memory decode streams from the file and hashes chunk by
    # chunk, so neither the whole input nor the whole output is held.
    def decode_file(path : String) : {Int64, String}
      digest = Digest::SHA256.new
      decoded_bytes = 0_i64
      File.open(path) do |file|
        each_decoded_chunk(file) do |chunk|
          digest.update(chunk)
          decoded_bytes += chunk.size
        end
      end
      {decoded_bytes, digest.hexfinal}
    end
  end
end
