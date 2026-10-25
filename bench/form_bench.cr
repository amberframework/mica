# Times one form-pair parser on generated inputs: Mica::Form::Pairs or
# stdlib URI::Params, each in its own process (bench/form_run.sh runs
# both). Prints one TSV line per input: impl, input, bytes, runs, median
# and minimum seconds, MB/s at the median, and a checksum of the pairs.
#
#   crystal-alpha build --release bench/form_bench.cr -o bench/bin/form_bench
#   bench/bin/form_bench mica 11
require "uri"
require "../src/mica"

impl = ARGV[0]? || abort("usage: form_bench mica|stdlib RUNS")
runs = (ARGV[1]? || "11").to_i

inputs = {
  "short_pairs" => (1..20_000).join('&') { |index| "field#{index}=value#{index}" },
  "escaped"     => (1..5_000).join('&') { |index| "name%5B#{index}%5D=caf%C3%A9+au+lait+%F0%9F%98%80+#{index}" },
  "long_value"  => "body=" + "%41b+" * 200_000,
  "rails_form"  => (1..2_000).join('&') { |index| "user[addresses][#{index}][street]=#{index}+Main+St&user[addresses][#{index}][city]=Springfield" },
}
limits = Mica::Form::Limits.unbounded(reason: "benchmark of trusted generated input")

inputs.each do |label, input|
  checksum = 0_u64
  run_once = -> do
    checksum = 0_u64
    if impl == "mica"
      Mica::Form::Pairs.each(input, limits: limits) { |pair| checksum &+= pair.field_name.bytesize &+ pair.field_value.bytesize }
    else
      URI::Params.parse(input) { |name, value| checksum &+= name.bytesize &+ value.bytesize }
    end
  end
  run_once.call
  timings = Array.new(runs) do
    started = Time.instant
    run_once.call
    (Time.instant - started).total_seconds
  end
  timings.sort!
  median = timings[timings.size // 2]
  megabytes_per_second = input.bytesize / median / 1_000_000
  puts [impl, label, input.bytesize, runs, median.round(6), timings.first.round(6), megabytes_per_second.round(1), checksum].join('\t')
end
