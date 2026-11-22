require "json"

module DeflateEncodeBench
  # What `mica_runner memory` prints: the bytes a streaming encode holds.
  record EncoderMemory, level : Int32, input_bytes : Int64, table_bytes : Int32, output_buffer_bytes : Int32,
    allocated_bytes : Int64 do
    include JSON::Serializable
  end

  # Measures what one `Mica::Deflate::Deflater` allocates for a whole
  # streaming encode of a file into a sink that discards: the collector's
  # allocation count before the encoder is built and after the stream is
  # finished. *table_bytes* is the window, the hash and chain tables and
  # the symbol buffer; *allocated_bytes* is everything, the output buffer
  # and the Huffman code builders included.
  class MeasureEncoderMemory
    private class DiscardingSink < IO
      def read(slice : Bytes) : NoReturn
        raise IO::Error.new("write-only")
      end

      def write(slice : Bytes) : Nil
      end
    end

    def initialize(@level : Int32, @input_path : String)
    end

    def perform : EncoderMemory
      buffer = Bytes.new(STREAM_BUFFER_BYTES)
      sink = DiscardingSink.new
      input_bytes = 0_i64
      File.open(@input_path) do |file|
        before = GC.stats.total_bytes
        deflater = Mica::Deflate::Deflater.new(Mica::Deflate::Format::Gzip, @level, sink)
        loop do
          read_bytes = file.read(buffer)
          break if read_bytes == 0
          input_bytes += read_bytes
          deflater.write(buffer[0, read_bytes])
        end
        deflater.finish
        allocated_bytes = (GC.stats.total_bytes - before).to_i64
        return EncoderMemory.new(@level, input_bytes, deflater.table_bytes, deflater.output_buffer_bytes, allocated_bytes)
      end
    end
  end
end
