require "compress/gzip"
require "compress/zlib"
require "compress/deflate"

module DeflateBench
  # Crystal's stdlib readers (`Compress::Gzip::Reader` and its zlib and raw
  # DEFLATE siblings), read through a 64 KiB slice: what a Crystal program
  # uses today. A context row, not the baseline.
  class StdlibReaderEngine < StreamingEngine
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
      in .gzip?    then Compress::Gzip::Reader.new(io)
      in .zlib?    then Compress::Zlib::Reader.new(io)
      in .deflate? then Compress::Deflate::Reader.new(io)
      end
    end
  end
end
