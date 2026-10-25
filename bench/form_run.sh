#!/bin/sh
# Builds bench/form_bench.cr with --release and runs Mica::Form::Pairs and
# stdlib URI::Params, each in its own process, one warm-up plus $RUNS timed
# runs per input. Prints the load average first.
set -eu
cd "$(dirname "$0")/.."
RUNS=${RUNS:-11}
mkdir -p bench/bin
crystal-alpha build --release bench/form_bench.cr -o bench/bin/form_bench
uptime
printf 'impl\tinput\tbytes\truns\tmedian_s\tmin_s\tmb_per_s\tchecksum\n'
./bench/bin/form_bench mica "$RUNS"
./bench/bin/form_bench stdlib "$RUNS"
