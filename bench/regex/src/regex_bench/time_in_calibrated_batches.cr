module RegexBench
  # When a phase of a case is sampled, then it times the phase's operation
  # in batches long enough for the clock to resolve, and reports seconds
  # per operation.
  #
  # The monotonic clock ticks every 41.67 ns on Apple Silicon, so an
  # operation of a few hundred nanoseconds reads as 1 to 3 ticks and its
  # median cannot be compared with another engine's. Calibration times a
  # batch of one operation, and doubles the batch until two timings of it
  # in a row each take at least `MeasurementSettings#min_batch_seconds`
  # (10 us): two, so a one-off slow call (a lazily built structure, a page
  # fault, a collection) does not decide the batch. Every sample then times
  # that many operations in one timed loop and divides by the batch size.
  # When the samples' median batch still took less than 10 us, the batch
  # doubles and the phase is sampled again, so the median sample is always
  # at least 10 us long.
  #
  # An operation that takes 10 us or more on its own keeps a batch of one,
  # and its two calibration timings are its first samples, as before
  # batching; one slower than `slow_iteration_seconds` is timed once.
  #
  # Every engine runs this same code over the same operation, in its own
  # process; the batch size each one settled on is recorded in
  # `Statistics#iterations_per_sample`.
  #
  # *before_each_batch* runs before each batch's clock starts, with the
  # batch size: `MeasureACase` makes each run's own haystack copy there, so
  # the copy is never timed. The block gets the run's index in its batch.
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

    # Leaves the setup before each batch empty.
    NO_PREPARATION = ->(_iterations : Int32) { nil }

    # Calibrates the batch for the block's operation, then samples it.
    def measure(before_each_batch : Int32 -> Nil = NO_PREPARATION, & : Int32 -> _) : Statistics
      list_of_seconds = [] of Float64
      iterations_per_sample = 1
      loop do
        first = time_a_batch(iterations_per_sample, before_each_batch) { |index| yield index }
        if iterations_per_sample == 1 && first >= @settings.slow_iteration_seconds
          list_of_seconds << first
          break
        end
        next iterations_per_sample *= 2 unless long_enough?(first, iterations_per_sample)
        second = time_a_batch(iterations_per_sample, before_each_batch) { |index| yield index }
        next iterations_per_sample *= 2 unless long_enough?(second, iterations_per_sample)
        # A batch of one keeps its calibration timings as its first samples.
        list_of_seconds.concat({first, second}) if iterations_per_sample == 1
        break
      end
      loop do
        take_samples(list_of_seconds, iterations_per_sample, before_each_batch) { |index| yield index }
        break if long_enough?(Statistics.of(list_of_seconds).median, iterations_per_sample)
        list_of_seconds.clear
        iterations_per_sample *= 2
      end
      Statistics.of(list_of_seconds.map { |batch_seconds| batch_seconds / iterations_per_sample },
        iterations_per_sample)
    end

    # True when a batch of *iterations_per_sample* operations took *seconds*,
    # at least `min_batch_seconds`, or the batch cannot grow.
    private def long_enough?(seconds : Float64, iterations_per_sample : Int32) : Bool
      seconds >= @settings.min_batch_seconds || iterations_per_sample >= MAX_ITERATIONS_PER_SAMPLE
    end

    # Adds batch timings to *list_of_seconds* until the sample loop's rules
    # say there are enough; the phase clock starts now.
    private def take_samples(list_of_seconds : Array(Float64), iterations_per_sample : Int32,
                             before_each_batch : Int32 -> Nil, & : Int32 -> _) : Nil
      phase_started = @clock.call
      until enough?(list_of_seconds, phase_started)
        list_of_seconds << time_a_batch(iterations_per_sample, before_each_batch) { |index| yield index }
      end
    end

    # The seconds *iterations* operations take, timed as one, after the
    # batch's untimed setup.
    private def time_a_batch(iterations : Int32, before_each_batch : Int32 -> Nil, & : Int32 -> _) : Float64
      before_each_batch.call(iterations)
      started = @clock.call
      iterations.times { |index| yield index }
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
