#!/bin/sh
# The YAML benchmark: Mica::YAML against libyaml on real configuration
# files. One command fetches and verifies the corpus, builds the runners
# with --release, runs the interleaved A/B rounds and writes the report:
#
#   bench/yaml/run.sh                 # 7 rounds
#   bench/yaml/run.sh --rounds 3      # anything after the script name goes to scripts/run_ab.rb
#
# With CRYSTAL_MICA_STDLIB set to the src/ directory of a crystal-alpha
# fork checkout that has the -Duse_mica YAML engine, and CRYSTAL_BIN to a
# compiler binary that matches it, a second runner is built from that
# standard library with -Duse_mica, and the report also measures the
# standard library's YAML::PullParser and YAML.parse_all on Mica (the
# compatibility layer) against the same calls on libyaml.
#
# The report is bench/data/yaml/runs/<UTC time>/REPORT.md, with
# results.json, samples.tsv and run.json beside it. See docs/yaml.md.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$ROOT/.crystal}"

/usr/bin/ruby bench/yaml/scripts/fetch_corpus.rb

BIN="$ROOT/bench/bin/yaml"
mkdir -p "$BIN"
crystal-alpha build --release bench/yaml/runner.cr -o "$BIN/runner"
rm -f "$BIN/runner_flag"
if [ -n "${CRYSTAL_MICA_STDLIB:-}" ]; then
  # Its own cache directory: the two builds share a main file and differ
  # in standard library and flags.
  CRYSTAL_CACHE_DIR="$CRYSTAL_CACHE_DIR-use-mica" CRYSTAL_PATH="lib:$CRYSTAL_MICA_STDLIB" "${CRYSTAL_BIN:?set CRYSTAL_BIN to the compiler binary}" build --release \
    -Duse_mica -Dyaml_stdlib_only bench/yaml/runner.cr -o "$BIN/runner_flag"
  if otool -L "$BIN/runner_flag" | grep -q libyaml; then
    echo "runner_flag links libyaml: the standard library at $CRYSTAL_MICA_STDLIB has no -Duse_mica YAML engine" >&2
    exit 1
  fi
fi

OUT="$ROOT/bench/data/yaml/runs/$(date -u +%Y%m%dT%H%M%SZ)"
/usr/bin/ruby bench/yaml/scripts/run_ab.rb --bin "$BIN" --out "$OUT" "$@"
