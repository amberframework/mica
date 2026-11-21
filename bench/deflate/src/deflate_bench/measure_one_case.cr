require "digest/sha256"

module DeflateBench
  # Times one engine on one case: one warm-up decode, then `sample_count`
  # timed samples. Every sample's output is hashed after its clock stops
  # and must equal the original file's sha256.
  #
  # A decode shorter than `MINIMUM_SAMPLE_SECONDS` is timed in batches, by
  # this code for every engine: the batch doubles until one batch takes at
  # least that long, then each sample times one batch and divides by its
  # size. The output of a batch's last decode is the one hashed.
  class MeasureOneCase
    MINIMUM_SAMPLE_SECONDS   =   0.01
    MAXIMUM_BATCH_ITERATIONS = 16_384

    def initialize(@engine_name : String, @engine : Engine, @compressed_path : String,
                   @expected_sha256 : String, @sample_count : Int32)
    end

    def perform : Measurement
      compressed = File.open(@compressed_path, &.getb_to_end)
      warm_up_seconds = seconds_of_a_verified_batch(compressed, 1)
      iterations = iterations_per_sample_after(compressed, warm_up_seconds)
      list_of_seconds = Array(Float64).new(@sample_count) do
        seconds_of_a_verified_batch(compressed, iterations) / iterations
      end
      Measurement.new(@engine_name, @engine.format.to_s.downcase, compressed.size.to_i64, @engine.expected_bytes,
        @expected_sha256, iterations, warm_up_seconds, list_of_seconds)
    end

    private def iterations_per_sample_after(compressed : Bytes, warm_up_seconds : Float64) : Int32
      return 1 if warm_up_seconds >= MINIMUM_SAMPLE_SECONDS
      iterations = 2
      while iterations < MAXIMUM_BATCH_ITERATIONS &&
            seconds_of_a_verified_batch(compressed, iterations) < MINIMUM_SAMPLE_SECONDS
        iterations *= 2
      end
      iterations
    end

    private def seconds_of_a_verified_batch(compressed : Bytes, iterations : Int32) : Float64
      output = Bytes.empty
      started = Time.instant
      iterations.times { output = @engine.decode(compressed) }
      seconds = (Time.instant - started).total_seconds
      verify(output)
      seconds
    end

    private def verify(output : Bytes) : Nil
      sha256 = Digest::SHA256.hexdigest(output)
      return if output.size == @engine.expected_bytes && sha256 == @expected_sha256
      raise OutputMismatchError.new("#{@engine_name} on #{@compressed_path}: decoded #{output.size} bytes " \
                                    "with sha256 #{sha256}; the original is #{@engine.expected_bytes} bytes " \
                                    "with sha256 #{@expected_sha256}")
    end
  end
end
