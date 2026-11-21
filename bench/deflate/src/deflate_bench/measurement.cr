require "json"

module DeflateBench
  # What a `measure` process prints: the timed samples of one engine on one
  # case, in seconds per decode, and the throughput they give in MB
  # (1,000,000 bytes) of decoded output per second.
  struct Measurement
    include JSON::Serializable

    getter engine : String
    getter format : String
    getter compressed_bytes : Int64
    getter output_bytes : Int64
    getter output_sha256 : String
    # Decodes timed as one sample (more than 1 when one decode is too short
    # for the clock; see `MeasureOneCase`).
    getter iterations_per_sample : Int32
    getter warm_up_seconds : Float64
    getter list_of_seconds : Array(Float64)
    getter median_seconds : Float64
    getter minimum_seconds : Float64
    getter median_mb_per_second : Float64
    getter best_mb_per_second : Float64

    def initialize(@engine, @format, @compressed_bytes, @output_bytes, @output_sha256, @iterations_per_sample,
                   @warm_up_seconds, @list_of_seconds)
      sorted = @list_of_seconds.sort
      @median_seconds = sorted[sorted.size // 2]
      @minimum_seconds = sorted.first
      megabytes = @output_bytes / 1_000_000.0
      @median_mb_per_second = megabytes / @median_seconds
      @best_mb_per_second = megabytes / @minimum_seconds
    end
  end

  # What a `once` process prints. Its peak memory is measured from outside
  # by /usr/bin/time -l.
  record PeakMemoryDecode, engine : String, format : String, output_bytes : Int64, output_sha256 : String do
    include JSON::Serializable
  end
end
