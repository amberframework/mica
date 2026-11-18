require "json"

module RegexBench
  # The spread of one measurement's samples, in seconds. An empty
  # measurement (no samples) has every field 0.
  struct Statistics
    include JSON::Serializable

    getter sample_count : Int32 = 0
    getter median : Float64 = 0.0
    getter p25 : Float64 = 0.0
    getter p75 : Float64 = 0.0
    getter min : Float64 = 0.0
    getter max : Float64 = 0.0

    def initialize(@sample_count = 0, @median = 0.0, @p25 = 0.0, @p75 = 0.0, @min = 0.0, @max = 0.0)
    end

    def self.of(list_of_seconds : Array(Float64)) : self
      return new if list_of_seconds.empty?
      sorted = list_of_seconds.sort
      new(sample_count: sorted.size, median: percentile(sorted, 0.5), p25: percentile(sorted, 0.25),
        p75: percentile(sorted, 0.75), min: sorted.first, max: sorted.last)
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

    def has_samples? : Bool
      @sample_count > 0
    end

    # (p75 - p25) / median.
    def relative_spread : Float64
      @median > 0 ? (@p75 - @p25) / @median : 0.0
    end
  end
end
