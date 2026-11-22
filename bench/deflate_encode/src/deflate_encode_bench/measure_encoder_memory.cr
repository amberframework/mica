require "json"

module DeflateEncodeBench
  # What `mica_runner memory` prints: the bytes a streaming encode holds.
  record EncoderMemory, level : Int32, input_bytes : Int64, table_bytes : Int32, output_buffer_bytes : Int32,
    workspace_bytes : Int32, collector_bytes : Int64, allocated_bytes : Int64 do
    include JSON::Serializable
  end

  # Measures what one `Mica::Deflate::Deflater` holds for a whole streaming
  # encode of a file into a sink that discards. *table_bytes* is the
  # window, the hash and chain tables and the symbol buffer,
  # *output_buffer_bytes* the output buffer and *workspace_bytes* the
  # Huffman code builders' arrays; all three come from libc's allocator in
  # sizes the engine fixes. *collector_bytes* is the collector's
  # allocation count from before the encoder is built to after the stream
  # is finished (the objects); *allocated_bytes* is the sum of the four.
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
        table_bytes = deflater.table_bytes
        deflater.finish
        collector_bytes = (GC.stats.total_bytes - before).to_i64
        output_buffer_bytes = deflater.output_buffer_bytes
        workspace_bytes = deflater.workspace_bytes
        return EncoderMemory.new(@level, input_bytes, table_bytes, output_buffer_bytes, workspace_bytes, collector_bytes,
          table_bytes + output_buffer_bytes + workspace_bytes + collector_bytes)
      end
    end
  end
end
