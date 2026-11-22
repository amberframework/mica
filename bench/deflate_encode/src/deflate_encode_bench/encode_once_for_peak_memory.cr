module DeflateEncodeBench
  # One encode and nothing else, so the process's maximum resident set
  # size (read from outside with /usr/bin/time -l) is that engine's peak
  # memory for the case.
  class EncodeOnceForPeakMemory
    def initialize(@engine_name : String, @engine : Engine, @input_path : String)
    end

    def perform : PeakMemoryEncode
      compressed_bytes = @engine.encode_file(@input_path)
      PeakMemoryEncode.new(@engine_name, @engine.level, File.size(@input_path), compressed_bytes)
    end
  end
end
