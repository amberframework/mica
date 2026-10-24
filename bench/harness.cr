# Shared timing loop for the benchmark programs.
#
# Usage: <program> WORKLOAD FILE ITERATIONS
# Prints one tab-separated line:
#   impl workload file bytes iterations median_s min_s max_s mb_per_s checksum
module BenchHarness
  def self.run(impl : String, & : String, String, Bool -> Int64) : Nil
    workload = ARGV[0]? || abort "usage: WORKLOAD FILE ITERATIONS"
    path = ARGV[1]? || abort "usage: WORKLOAD FILE ITERATIONS"
    iterations = (ARGV[2]? || "5").to_i
    bytes = File.size(path)
    # The warm-up run computes the cross-implementation checksum; timed runs
    # skip work that is only there to verify results.
    checksum = yield workload, path, true
    if iterations == 0
      # Memory mode: one verified run only, measured from outside.
      puts [impl, workload, File.basename(path), bytes, 0, checksum].join('\t')
      return
    end
    times = [] of Float64
    iterations.times do
      started = Time.instant
      yield workload, path, false
      times << (Time.instant - started).total_seconds
    end
    times.sort!
    median = times[times.size // 2]
    mb_per_s = bytes / 1_000_000.0 / median
    puts [impl, workload, File.basename(path), bytes, iterations,
          median.round(5), times.first.round(5), times.last.round(5), mb_per_s.round(1), checksum].join('\t')
  end
end
