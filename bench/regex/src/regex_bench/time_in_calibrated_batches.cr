module RegexBench
  # When a phase of a case is sampled, then it times the phase's operation
  # in batches long enough for the clock to resolve, and reports seconds
  # per operation.
  #
  # The monotonic clock ticks every 41.67 ns on Apple Silicon, so an
  # operation of a few hundred nanoseconds reads as 1 to 3 ticks and its
  # median cannot be compared with another engine's. Calibration times one
  # operation; while that takes less than `MeasurementSettings#min_batch_seconds`
  # (10 us), it doubles the batch and times the whole batch again, until
  # one batch takes at least that long. Every sample then times that many
  # operations in one timed loop and divides by the batch size. An
  # operation that takes 10 us or more on its own keeps a batch of one,
  # and its first timing is its first sample, exactly as before batching.
  #
  # Every engine runs this same code over the same operation, in its own
  # process; the batch size each one settled on is recorded in
  # `Statistics#iterations_per_sample`.
  #
  # The sample loop's rules (`max_samples`, `min_samples`, `phase_seconds`,
  # `slow_iteration_seconds`) count batches: a batch is one sample.
  class TimeInCalibratedBatches
    # The most operations one batch may hold, so a phase whose operation
    # the clock reads as zero still ends.
    MAX_ITERATIONS_PER_SAMPLE = 1 << 20

    # *clock* returns monotonic seconds; specs pass a simulated one.
    def initialize(@settings : MeasurementSettings, @clock : Proc(Float64) = ->TimeInCalibratedBatches.monotonic_seconds)
    end

    # Seconds on the monotonic clock since an arbitrary start.
    def self.monotonic_seconds : Float64
      (Time.instant - START).total_seconds
    end

    private START = Time.instant

    # Calibrates the batch for the block's operation, then samples it.
    def measure(& : -> _) : Statistics
      phase_started = @clock.call
      iterations_per_sample = 1
      seconds = time_a_batch(iterations_per_sample) { yield }
      while seconds < @settings.min_batch_seconds && iterations_per_sample < MAX_ITERATIONS_PER_SAMPLE
        iterations_per_sample *= 2
        seconds = time_a_batch(iterations_per_sample) { yield }
      end
      list_of_seconds = [] of Float64
      # A batch of one is the operation timed alone: its calibration timing
      # is its first sample. A larger batch starts sampling after calibration.
      list_of_seconds << seconds if iterations_per_sample == 1
      phase_started = @clock.call if iterations_per_sample > 1
      until enough?(list_of_seconds, phase_started)
        list_of_seconds << time_a_batch(iterations_per_sample) { yield }
      end
      Statistics.of(list_of_seconds.map { |batch_seconds| batch_seconds / iterations_per_sample },
        iterations_per_sample)
    end

    # The seconds *iterations* operations take, timed as one.
    private def time_a_batch(iterations : Int32, & : -> _) : Float64
      started = @clock.call
      iterations.times { yield }
      @clock.call - started
    end

    private def enough?(list_of_seconds : Array(Float64), phase_started : Float64) : Bool
      return false if list_of_seconds.empty?
      return true if list_of_seconds.last >= @settings.slow_iteration_seconds
      return true if list_of_seconds.size >= @settings.max_samples
      list_of_seconds.size >= @settings.min_samples && @clock.call - phase_started >= @settings.phase_seconds
    end
  end
end
