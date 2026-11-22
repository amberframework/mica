require "json"

module DeflateEncodeBench
  # What a `measure` process prints: the timed samples of one engine on one
  # case, in seconds per encode, and the throughput they give in MB
  # (1,000,000 bytes) of input per second.
  struct Measurement
    include JSON::Serializable

    getter engine : String
    getter level : Int32
    getter input_bytes : Int64
    getter input_sha256 : String
    getter compressed_bytes : Int64
    getter compressed_sha256 : String
    # Encodes timed as one sample (more than 1 when one encode is too short
    # for the clock; see `MeasureOneCase`).
    getter iterations_per_sample : Int32
    getter warm_up_seconds : Float64
    # True when the warm-up encode is also the first sample (an encode
    # longer than `MeasureOneCase::LONG_ENCODE_SECONDS`).
    getter warm_up_is_a_sample : Bool
    getter list_of_seconds : Array(Float64)
    getter median_seconds : Float64
    getter minimum_seconds : Float64
    getter median_mb_per_second : Float64
    getter best_mb_per_second : Float64

    def initialize(@engine, @level, @input_bytes, @input_sha256, @compressed_bytes, @compressed_sha256,
                   @iterations_per_sample, @warm_up_seconds, @warm_up_is_a_sample, @list_of_seconds)
      sorted = @list_of_seconds.sort
      middle = sorted.size // 2
      @median_seconds = sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
      @minimum_seconds = sorted.first
      megabytes = @input_bytes / 1_000_000.0
      @median_mb_per_second = megabytes / @median_seconds
      @best_mb_per_second = megabytes / @minimum_seconds
    end
  end

  # What a `once` process prints. Its peak memory is measured from outside
  # by /usr/bin/time -l.
  record PeakMemoryEncode, engine : String, level : Int32, input_bytes : Int64, compressed_bytes : Int64 do
    include JSON::Serializable
  end
end
