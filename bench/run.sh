#!/bin/sh
# Builds both benchmark programs with --release, then for every input and
# workload prints throughput (median of $ITERATIONS timed runs after one
# warm-up) and peak RSS (a separate process doing one run, measured by
# /usr/bin/time -l).
set -eu
cd "$(dirname "$0")/.."
ITERATIONS=${ITERATIONS:-7}
mkdir -p bench/bin
crystal-alpha build --release bench/bench_mica.cr -o bench/bin/bench_mica
crystal-alpha build --release bench/bench_stdlib.cr -o bench/bin/bench_stdlib
printf 'impl\tworkload\tfile\tbytes\titerations\tmedian_s\tmin_s\tmax_s\tmb_per_s\tchecksum\tpeak_rss_mb\n'
for file in s3_list_objects rss_feed synthetic_50mb deep_nesting attribute_heavy; do
  for workload in dom reader xpath; do
    if [ "$workload" = xpath ] && [ "$file" != s3_list_objects ]; then continue; fi
    for impl in mica stdlib; do
      line=$(./bench/bin/bench_$impl $workload bench/data/$file.xml "$ITERATIONS")
      rss=$( { /usr/bin/time -l ./bench/bin/bench_$impl $workload bench/data/$file.xml 0 >/dev/null; } 2>&1 | awk '/maximum resident set size/ {printf "%.1f", $1/1048576}')
      printf '%s\t%s\n' "$line" "$rss"
    done
  done
done
