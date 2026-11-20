module RegexBench
  # How many samples a measurement takes and how long it may run.
  record MeasurementSettings,
    max_samples : Int32 = 11,
    min_samples : Int32 = 3,
    phase_seconds : Float64 = 1.0,
    warmup_seconds : Float64 = 0.5,
    slow_iteration_seconds : Float64 = 2.0,
    min_batch_seconds : Float64 = 10e-6

  # When an engine runner is handed a case, then it builds the haystack,
  # times the process-cold first search (compile plus first search, the
  # first regex work of the runner process), verifies the model's count, and
  # takes compile, cold-first-search and warm-search samples, then reports
  # peak memory.
  #
  # Statistical method: one verified iteration, then warm-up iterations
  # (up to 3, within `warmup_seconds`), then samples until `max_samples` or
  # until `phase_seconds` has passed with at least `min_samples`. An
  # iteration slower than `slow_iteration_seconds` ends its phase after that
  # sample, so a pathological search is timed once rather than N times.
  # An operation shorter than `min_batch_seconds` (10 us) is timed in
  # calibrated batches (see `TimeInCalibratedBatches`), for every engine
  # alike, and its batch size is recorded with its statistics.
  #
  # Every timed cold and warm search gets its own String equal to the
  # haystack, made before its batch's clock starts (see `HaystackCopies`),
  # as a web app gets a new String per request.
  class MeasureACase
    def initialize(@engine : Engine, @benchmark_case : BenchmarkCase, @settings : MeasurementSettings,
                   @rebar_haystack_directory : String)
      @policy = SearchPolicy.new(deadline: @benchmark_case.deadline,
        untrusted_input: @benchmark_case.belongs_to_the_redos_set?)
      @haystack_bytes = 0_i64
      @haystack_checksum = ""
      @rss_after_haystack = 0_i64
    end

    def perform : CaseResult
      return result("pending", detail: @engine.pending_reason) unless @engine.ready?

      haystack = HaystackBuilder.new(@benchmark_case.haystack, @rebar_haystack_directory).build
      @haystack_bytes = haystack.bytesize.to_i64
      @haystack_checksum = HaystackGenerator.checksum(haystack).to_s(16)
      @rss_after_haystack = PeakMemory.bytes
      measure(haystack)
    rescue error : UnsupportedCaseError
      result("unsupported", detail: error.message || error.class.name)
    end

    private def measure(haystack : String) : CaseResult
      ProcessCold.leave_the_collector_at_rest
      started = Time.instant
      compiled = compile
      compiled.find(haystack, 0, true, false)
      process_first = elapsed_since(started)

      workload = Workload.new(compiled, haystack, @benchmark_case.model)
      started = Time.instant
      count = workload.run
      verify_seconds = elapsed_since(started)

      copies = HaystackCopies.new(haystack)
      compile_statistics = sample { compile }
      cold_statistics = if takes_one_slow_search?(process_first)
                          Statistics.of([process_first])
                        else
                          sample_over_copies(copies) { |copy| compile.find(copy, 0, true, false) }
                        end
      warm_statistics = if verify_seconds >= @settings.slow_iteration_seconds
                          Statistics.of([verify_seconds])
                        else
                          warm_up(workload, copies, verify_seconds)
                          sample_over_copies(copies) { |copy| workload.run(copy) }
                        end

      result("ok", count: count, compile: compile_statistics, cold_first_search: cold_statistics,
        process_first_search_seconds: process_first, warm_search: warm_statistics)
    rescue error : LimitReachedError
      result("limit", detail: error.message || error.class.name, limit_name: error.limit_name,
        seconds_until_limit: started ? elapsed_since(started) : 0.0)
    end

    private def compile : CompiledPattern
      @engine.compile(@benchmark_case.pattern, @benchmark_case.case_insensitive?, @policy)
    end

    private def takes_one_slow_search?(seconds : Float64) : Bool
      @benchmark_case.model == "first-match" && seconds >= @settings.slow_iteration_seconds
    end

    private def warm_up(workload : Workload, copies : HaystackCopies, spent : Float64) : Nil
      iterations = 1
      while iterations < 3 && spent < @settings.warmup_seconds
        copies.prepare(1)
        started = Time.instant
        workload.run(copies[0])
        spent += elapsed_since(started)
        iterations += 1
      end
    end

    private def sample(& : -> _) : Statistics
      TimeInCalibratedBatches.new(@settings).measure { yield }
    end

    # Samples the block over a fresh copy of the haystack per run; the
    # copies for each batch are made before its clock starts.
    private def sample_over_copies(copies : HaystackCopies, & : String -> _) : Statistics
      prepare = ->(iterations : Int32) { copies.prepare(iterations) }
      TimeInCalibratedBatches.new(@settings).measure(prepare) { |index| yield copies[index] }
    end

    private def elapsed_since(started : Time::Instant) : Float64
      (Time.instant - started).total_seconds
    end

    private def result(status : String, *, detail : String = "", limit_name : String = "", count : Int64 = -1_i64,
                       compile : Statistics = Statistics.new, cold_first_search : Statistics = Statistics.new,
                       process_first_search_seconds : Float64 = 0.0, warm_search : Statistics = Statistics.new,
                       seconds_until_limit : Float64 = 0.0) : CaseResult
      CaseResult.new(benchmark_case: @benchmark_case, engine: @engine.name, status: status, detail: detail,
        limit_name: limit_name, haystack_bytes: @haystack_bytes, haystack_checksum: @haystack_checksum,
        count: count, compile: compile, cold_first_search: cold_first_search,
        process_first_search_seconds: process_first_search_seconds, warm_search: warm_search,
        seconds_until_limit: seconds_until_limit, rss_after_haystack_bytes: @rss_after_haystack,
        peak_rss_bytes: PeakMemory.bytes)
    end
  end

  # Reads the process's peak resident set size.
  module PeakMemory
    def self.bytes : Int64
      usage = uninitialized LibC::RUsage
      return 0_i64 unless LibC.getrusage(LibC::RUSAGE_SELF, pointerof(usage)) == 0
      {% if flag?(:darwin) %}
        usage.ru_maxrss.to_i64 # bytes on macOS
      {% else %}
        usage.ru_maxrss.to_i64 * 1024 # kilobytes on Linux
      {% end %}
    end
  end
end
