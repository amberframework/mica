module DeflateBench
  # Builds an engine for a case's format and known output size.
  alias EngineBuilder = Proc(Format, Int64, Engine)

  # The command line both runners share:
  #
  #   RUNNER measure ENGINE FORMAT COMPRESSED OUTPUT_BYTES OUTPUT_SHA256 SAMPLES
  #   RUNNER once    ENGINE FORMAT COMPRESSED OUTPUT_BYTES OUTPUT_SHA256
  #
  # Each prints one JSON line (`Measurement` or `PeakMemoryDecode`). A decode
  # whose output is not the original file exits non-zero with the reason.
  class RunTheRunner
    USAGE = "usage: measure|once ENGINE FORMAT COMPRESSED OUTPUT_BYTES OUTPUT_SHA256 [SAMPLES]"

    def initialize(@list_of_arguments : Array(String), @engine_builders : Hash(String, EngineBuilder))
    end

    def perform : Nil
      command = @list_of_arguments[0]? || raise UsageError.new(USAGE)
      raise UsageError.new(USAGE) unless @list_of_arguments.size >= 6
      engine_name = @list_of_arguments[1]
      builder = @engine_builders[engine_name]? ||
                raise UsageError.new("unknown engine #{engine_name} (#{@engine_builders.keys.join(", ")})")
      engine = builder.call(Format.named(@list_of_arguments[2]), @list_of_arguments[4].to_i64)
      compressed_path = @list_of_arguments[3]
      expected_sha256 = @list_of_arguments[5]
      case command
      when "measure"
        sample_count = (@list_of_arguments[6]? || "11").to_i
        STDOUT.puts MeasureOneCase.new(engine_name, engine, compressed_path, expected_sha256, sample_count).perform.to_json
      when "once"
        STDOUT.puts DecodeOnceForPeakMemory.new(engine_name, engine, compressed_path, expected_sha256).perform.to_json
      else
        raise UsageError.new(USAGE)
      end
    end

    # Runs the command and turns a harness error into a message and exit
    # status 1 (2 for a usage error). Engine errors are left to crash the
    # process with their own trace.
    def self.perform_or_exit(list_of_arguments : Array(String), engine_builders : Hash(String, EngineBuilder)) : Nil
      new(list_of_arguments, engine_builders).perform
    rescue error : UsageError
      STDERR.puts error.message
      exit 2
    rescue error : Error
      STDERR.puts "#{error.class.name}: #{error.message}"
      exit 1
    end
  end
end
