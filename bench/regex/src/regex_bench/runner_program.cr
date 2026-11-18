require "json"

module RegexBench
  # Describes an engine for the run record.
  struct EngineDescription
    include JSON::Serializable

    getter engine : String
    getter version : String
    getter? ready : Bool
    getter pending_reason : String = ""

    def initialize(@engine, @version, @ready, @pending_reason = "")
    end
  end

  # The command line of an engine runner program. The driver writes one
  # case as JSON to the runner's standard input; the runner measures it and
  # writes one `CaseResult` as a JSON line to standard output.
  #
  #   <runner> [--rebar-haystacks DIR] [--max-samples N] [--min-samples N]
  #            [--phase-seconds S] < case.json
  #   <runner> --describe
  class RunnerProgram
    def initialize(@engine : Engine, @list_of_arguments : Array(String), @input : IO, @output : IO)
      @rebar_haystack_directory = ""
      @settings = MeasurementSettings.new
      @describe_only = false
    end

    def run : Nil
      parse_arguments
      if @describe_only
        EngineDescription.new(@engine.name, @engine.version, @engine.ready?, @engine.pending_reason).to_json(@output)
      else
        benchmark_case = BenchmarkCase.from_json(@input.gets_to_end)
        MeasureACase.new(@engine, benchmark_case, @settings, @rebar_haystack_directory).perform.to_json(@output)
      end
      @output.puts
      @output.flush
    end

    # Parses `--name value` pairs by hand: stdlib OptionParser matches its
    # flags with Regex, which would link PCRE2 into the Mica runner.
    private def parse_arguments : Nil
      max_samples = @settings.max_samples
      min_samples = @settings.min_samples
      phase_seconds = @settings.phase_seconds
      index = 0
      while index < @list_of_arguments.size
        flag = @list_of_arguments[index]
        if flag == "--describe"
          @describe_only = true
          index += 1
          next
        end
        value = @list_of_arguments[index + 1]? || raise Error.new("#{flag} needs a value")
        case flag
        when "--rebar-haystacks" then @rebar_haystack_directory = value
        when "--max-samples"     then max_samples = value.to_i
        when "--min-samples"     then min_samples = value.to_i
        when "--phase-seconds"   then phase_seconds = value.to_f
        else                          raise Error.new("unknown option #{flag}")
        end
        index += 2
      end
      @settings = MeasurementSettings.new(max_samples: max_samples, min_samples: min_samples, phase_seconds: phase_seconds)
    end
  end
end
