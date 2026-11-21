require "json"

module RegexBench
  # The spread of one measurement's samples, in seconds per operation. An
  # empty measurement (no samples) has every field 0.
  #
  # `iterations_per_sample` is the batch each sample timed as one and
  # divided by (see `TimeInCalibratedBatches`): 1 when each operation was
  # timed alone.
  # A ratio with the low and high ends of its confidence interval.
  record RatioInterval, ratio : Float64, low : Float64, high : Float64 do
    include JSON::Serializable

    def includes?(value : Float64) : Bool
      @low <= value <= @high
    end
  end

  struct Statistics
    include JSON::Serializable

    getter sample_count : Int32 = 0
    getter median : Float64 = 0.0
    getter p25 : Float64 = 0.0
    getter p75 : Float64 = 0.0
    getter min : Float64 = 0.0
    getter max : Float64 = 0.0
    getter iterations_per_sample : Int32 = 1

    def initialize(@sample_count = 0, @median = 0.0, @p25 = 0.0, @p75 = 0.0, @min = 0.0, @max = 0.0,
                   @iterations_per_sample = 1)
    end

    def self.of(list_of_seconds : Array(Float64), iterations_per_sample : Int32 = 1) : self
      return new(iterations_per_sample: iterations_per_sample) if list_of_seconds.empty?
      sorted = list_of_seconds.sort
      new(sample_count: sorted.size, median: percentile(sorted, 0.5), p25: percentile(sorted, 0.25),
        p75: percentile(sorted, 0.75), min: sorted.first, max: sorted.last,
        iterations_per_sample: iterations_per_sample)
    end

    # Linear interpolation between the closest ranks.
    def self.percentile(sorted : Array(Float64), fraction : Float64) : Float64
      return sorted.first if sorted.size == 1
      rank = fraction * (sorted.size - 1)
      lower = rank.floor.to_i
      upper = rank.ceil.to_i
      sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - lower)
    end

    # Returns the geometric mean of *list_of_values*, or 0.0 when empty.
    def self.geometric_mean(list_of_values : Array(Float64)) : Float64
      return 0.0 if list_of_values.empty?
      Math.exp(list_of_values.sum { |value| Math.log(value) } / list_of_values.size)
    end

    # Returns the least-squares slope of log(y) over log(x): about 1 for
    # linear growth, 2 for quadratic. Needs two or more points.
    def self.log_log_slope(list_of_points : Array(Tuple(Float64, Float64))) : Float64
      return 0.0 if list_of_points.size < 2
      xs = list_of_points.map { |point| Math.log(point[0]) }
      ys = list_of_points.map { |point| Math.log(point[1]) }
      mean_x = xs.sum / xs.size
      mean_y = ys.sum / ys.size
      covariance = xs.zip(ys).sum { |x, y| (x - mean_x) * (y - mean_y) }
      variance = xs.sum { |x| (x - mean_x) ** 2 }
      variance == 0 ? 0.0 : covariance / variance
    end

    # Returns the median of the paired ratios numerator[i] / denominator[i]
    # with a paired bootstrap interval at *confidence*: each resample draws
    # the pairs again with replacement and takes the median ratio. Pairs
    # taken side by side cancel drift in the machine's speed. *seed* makes
    # the interval reproducible.
    def self.paired_ratio_interval(numerator : Array(Float64), denominator : Array(Float64), *,
                                   resamples : Int32 = 4000, confidence : Float64 = 0.95,
                                   seed : UInt64 = 1_u64) : RatioInterval
      raise ArgumentError.new("paired samples need equal, non-zero counts") if numerator.empty? || numerator.size != denominator.size
      list_of_pair_ratios = numerator.zip(denominator).map { |top, bottom| top / bottom }
      random = Random::PCG32.new(seed)
      list_of_medians = Array(Float64).new(resamples) do
        resample = Array(Float64).new(list_of_pair_ratios.size) { list_of_pair_ratios.sample(random) }
        percentile(resample.sort!, 0.5)
      end
      list_of_medians.sort!
      tail = (1.0 - confidence) / 2
      RatioInterval.new(ratio: percentile(list_of_pair_ratios.sort, 0.5),
        low: percentile(list_of_medians, tail), high: percentile(list_of_medians, 1.0 - tail))
    end

    def has_samples? : Bool
      @sample_count > 0
    end

    # (p75 - p25) / median.
    def relative_spread : Float64
      @median > 0 ? (@p75 - @p25) / @median : 0.0
    end
  end
end
