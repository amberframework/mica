require "digest/sha256"

module DeflateEncodeBench
  # Times one engine on one case: one warm-up encode, then up to
  # `sample_count` timed samples. After each sample's clock stops its
  # output must equal the first output byte for byte, and the first output
  # is decoded and must hash to the original file's sha256.
  #
  # An encode shorter than `MINIMUM_SAMPLE_SECONDS` is timed in batches, by
  # this code for every engine: the batch doubles until one batch takes at
  # least that long, then each sample times one batch and divides by its
  # size.
  #
  # An encode longer than `LONG_ENCODE_SECONDS` is not repeated for a
  # warm-up: the warm-up's time is the first sample. Samples stop once the
  # timed encodes add up to `sample_budget_seconds`, so a case that takes
  # seconds per encode is sampled once or twice per process and its
  # statistics come from the rounds.
  class MeasureOneCase
    MINIMUM_SAMPLE_SECONDS   =   0.01
    MAXIMUM_BATCH_ITERATIONS = 16_384
    LONG_ENCODE_SECONDS      =    0.5

    @reference : Bytes = Bytes.empty

    def initialize(@engine_name : String, @engine : Engine, @input_path : String, @expected_sha256 : String,
                   @sample_count : Int32, @sample_budget_seconds : Float64)
    end

    def perform : Measurement
      input = File.open(@input_path, &.getb_to_end)
      input_sha256 = Digest::SHA256.hexdigest(input)
      unless input_sha256 == @expected_sha256
        raise OutputMismatchError.new("#{@input_path} has sha256 #{input_sha256}; the case expects #{@expected_sha256}")
      end
      warm_up_seconds = seconds_of_a_verified_batch(input, 1)
      warm_up_is_a_sample = warm_up_seconds >= LONG_ENCODE_SECONDS
      iterations = iterations_per_sample_after(input, warm_up_seconds)
      list_of_seconds = [] of Float64
      list_of_seconds << warm_up_seconds if warm_up_is_a_sample
      spent_seconds = list_of_seconds.sum
      while list_of_seconds.size < @sample_count
        break if !list_of_seconds.empty? && spent_seconds + list_of_seconds.min * iterations > @sample_budget_seconds
        seconds = seconds_of_a_verified_batch(input, iterations)
        spent_seconds += seconds
        list_of_seconds << seconds / iterations
      end
      Measurement.new(@engine_name, @engine.level, input.size.to_i64, input_sha256, @reference.size.to_i64,
        Digest::SHA256.hexdigest(@reference), iterations, warm_up_seconds, warm_up_is_a_sample, list_of_seconds)
    end

    private def iterations_per_sample_after(input : Bytes, warm_up_seconds : Float64) : Int32
      return 1 if warm_up_seconds >= MINIMUM_SAMPLE_SECONDS
      iterations = 2
      while iterations < MAXIMUM_BATCH_ITERATIONS && seconds_of_a_verified_batch(input, iterations) < MINIMUM_SAMPLE_SECONDS
        iterations *= 2
      end
      iterations
    end

    private def seconds_of_a_verified_batch(input : Bytes, iterations : Int32) : Float64
      output = Bytes.empty
      started = Time.instant
      iterations.times { output = @engine.encode(input) }
      seconds = (Time.instant - started).total_seconds
      verify(input, output)
      seconds
    end

    # The first output is decoded and compared with the input; every later
    # output must be the same bytes.
    private def verify(input : Bytes, output : Bytes) : Nil
      if @reference.empty?
        decoded = @engine.decode(output, input.size)
        unless decoded == input
          raise OutputMismatchError.new("#{@engine_name} on #{@input_path}: the stream decodes to #{decoded.size} bytes " \
                                        "that are not the #{input.size} bytes of the input")
        end
        @reference = output.dup
      elsif output != @reference
        raise OutputMismatchError.new("#{@engine_name} on #{@input_path}: an encode gave #{output.size} bytes that " \
                                      "differ from the first encode's #{@reference.size}")
      end
    end
  end
end
