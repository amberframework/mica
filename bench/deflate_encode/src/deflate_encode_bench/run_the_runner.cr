module DeflateEncodeBench
  # Builds an engine for a case's level.
  alias EngineBuilder = Proc(Int32, Engine)

  # The command line both runners share:
  #
  #   RUNNER measure ENGINE LEVEL INPUT INPUT_SHA256 [SAMPLES [BUDGET_SECONDS]]
  #   RUNNER once    ENGINE LEVEL INPUT
  #   RUNNER write   ENGINE LEVEL INPUT OUTPUT       writes the stream to OUTPUT
  #   RUNNER check   ENGINE COMPRESSED ORIGINAL      decodes COMPRESSED; it must equal ORIGINAL
  #
  # `measure` and `once` print one JSON line (`Measurement` or
  # `PeakMemoryEncode`). `write` and `check` let one library's decoder
  # check the other's stream. A failed check exits non-zero with the
  # reason.
  class RunTheRunner
    USAGE = "usage: measure|once|write|check ENGINE ... (see bench/deflate_encode/src/deflate_encode_bench/run_the_runner.cr)"

    def initialize(@list_of_arguments : Array(String), @engine_builders : Hash(String, EngineBuilder))
    end

    def perform : Nil
      command = @list_of_arguments[0]? || raise UsageError.new(USAGE)
      engine_name = @list_of_arguments[1]? || raise UsageError.new(USAGE)
      builder = @engine_builders[engine_name]? ||
                raise UsageError.new("unknown engine #{engine_name} (#{@engine_builders.keys.join(", ")})")
      case command
      when "measure"
        raise UsageError.new(USAGE) unless @list_of_arguments.size >= 5
        sample_count = (@list_of_arguments[5]? || "11").to_i
        sample_budget_seconds = (@list_of_arguments[6]? || "1.5").to_f
        engine = builder.call(@list_of_arguments[2].to_i)
        STDOUT.puts MeasureOneCase.new(engine_name, engine, @list_of_arguments[3], @list_of_arguments[4], sample_count,
          sample_budget_seconds).perform.to_json
      when "once"
        raise UsageError.new(USAGE) unless @list_of_arguments.size >= 4
        engine = builder.call(@list_of_arguments[2].to_i)
        STDOUT.puts EncodeOnceForPeakMemory.new(engine_name, engine, @list_of_arguments[3]).perform.to_json
      when "write"
        raise UsageError.new(USAGE) unless @list_of_arguments.size >= 5
        engine = builder.call(@list_of_arguments[2].to_i)
        File.write(@list_of_arguments[4], engine.encode(File.open(@list_of_arguments[3], &.getb_to_end)))
      when "check"
        raise UsageError.new(USAGE) unless @list_of_arguments.size >= 4
        original = File.open(@list_of_arguments[3], &.getb_to_end)
        decoded = builder.call(6).decode(File.open(@list_of_arguments[2], &.getb_to_end), original.size)
        unless decoded == original
          raise OutputMismatchError.new("#{@list_of_arguments[2]} decodes to #{decoded.size} bytes that are not #{@list_of_arguments[3]}")
        end
        STDOUT.puts "ok"
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
