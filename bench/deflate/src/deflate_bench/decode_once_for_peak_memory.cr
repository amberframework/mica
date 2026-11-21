module DeflateBench
  # One verified decode and nothing else, so the process's maximum resident
  # set size (read from outside with /usr/bin/time -l) is that engine's
  # peak memory for the case.
  class DecodeOnceForPeakMemory
    def initialize(@engine_name : String, @engine : Engine, @compressed_path : String, @expected_sha256 : String)
    end

    def perform : PeakMemoryDecode
      decoded_bytes, sha256 = @engine.decode_file(@compressed_path)
      unless decoded_bytes == @engine.expected_bytes && sha256 == @expected_sha256
        raise OutputMismatchError.new("#{@engine_name} on #{@compressed_path}: decoded #{decoded_bytes} bytes " \
                                      "with sha256 #{sha256}; the original is #{@engine.expected_bytes} bytes " \
                                      "with sha256 #{@expected_sha256}")
      end
      PeakMemoryDecode.new(@engine_name, @engine.format.to_s.downcase, decoded_bytes, sha256)
    end
  end
end
