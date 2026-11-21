require "digest/sha256"
require "json"
require "./lib_system_z"

module DeflateBench
  # One compressed copy of an original file.
  record CompressedInput, format : String, path : String, bytes : Int64, sha256 : String do
    include JSON::Serializable
  end

  # What `zlib_runner compress` prints.
  record CompressedInputSet, original_sha256 : String, original_bytes : Int64, zlib_version : String,
    level : Int32, list_of_inputs : Array(CompressedInput) do
    include JSON::Serializable
  end

  # Compresses one original file with system zlib at one level into
  # `<output_prefix>.gz` (gzip, windowBits 31), `.zz` (zlib, 15) and
  # `.deflate` (raw, -15), each in a single `deflate(Z_FINISH)` call.
  class CompressWithSystemZlib
    def initialize(@original_path : String, @output_prefix : String, @level : Int32 = 6)
    end

    def perform : CompressedInputSet
      original = File.open(@original_path, &.getb_to_end)
      list_of_inputs = Format.values.map do |format|
        compressed = compress(original, format)
        path = "#{@output_prefix}.#{format.file_extension}"
        File.write(path, compressed)
        CompressedInput.new(format.to_s.downcase, path, compressed.size.to_i64, Digest::SHA256.hexdigest(compressed))
      end
      CompressedInputSet.new(Digest::SHA256.hexdigest(original), original.size.to_i64, SystemZ.version, @level,
        list_of_inputs)
    end

    private def compress(original : Bytes, format : Format) : Bytes
      stream = LibSystemZ::Stream.new
      SystemZ.check LibSystemZ.deflateInit2_(pointerof(stream), @level, SystemZ::DEFLATED, format.window_bits,
        SystemZ::MEMORY_LEVEL, SystemZ::DEFAULT_STRATEGY, LibSystemZ.zlibVersion,
        sizeof(LibSystemZ::Stream)), "deflateInit2"
      compressed = Bytes.new(LibSystemZ.deflateBound(pointerof(stream), original.size))
      stream.next_in = original.to_unsafe
      stream.avail_in = original.size.to_u32
      stream.next_out = compressed.to_unsafe
      stream.avail_out = compressed.size.to_u32
      status = LibSystemZ.deflate(pointerof(stream), SystemZ::FINISH)
      compressed_bytes = stream.total_out
      LibSystemZ.deflateEnd(pointerof(stream))
      raise ZlibError.new("deflate returned #{status}") unless status == SystemZ::STREAM_END
      compressed[0, compressed_bytes]
    end
  end
end
