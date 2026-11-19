module RegexBench
  # What came back from one runner process.
  record RunnerOutcome, standard_output : String, standard_error : String, timed_out : Bool,
    exit_description : String do
    def timed_out? : Bool
      timed_out
    end
  end

  # When a runner is started on one case, then the case JSON is written to
  # its standard input, its output is collected, and the process is killed
  # if it runs past *timeout_seconds*.
  class RunOneRunnerProcess
    def initialize(@binary : String, @list_of_arguments : Array(String), @standard_input : String,
                   @timeout_seconds : Float64)
    end

    def perform : RunnerOutcome
      process = Process.new(@binary, @list_of_arguments, input: :pipe, output: :pipe, error: :pipe)
      output_channel = Channel(String).new(1)
      error_channel = Channel(String).new(1)
      status_channel = Channel(Process::Status).new(1)
      spawn(name: "runner-stdout") { output_channel.send(process.output.gets_to_end) }
      spawn(name: "runner-stderr") { error_channel.send(process.error.gets_to_end) }
      process.input.print(@standard_input)
      process.input.close
      spawn(name: "runner-wait") { status_channel.send(process.wait) }

      timed_out = false
      select
      when status = status_channel.receive
      when timeout(@timeout_seconds.seconds)
        timed_out = true
        process.terminate(graceful: false)
        status = status_channel.receive
      end
      RunnerOutcome.new(output_channel.receive, error_channel.receive, timed_out, status.to_s)
    end
  end
end
