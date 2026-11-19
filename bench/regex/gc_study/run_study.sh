#!/bin/sh
# The GC-free study's paired benchmark run (docs/benchmarks.md, "GC-free
# study"): builds the PCRE2-JIT, Mica and Mica-static runners with
# --release, then runs every case in bench/regex/gc_study/case_list.txt in
# each engine's own process, the three engines one after another per case,
# so each pair is measured side by side in time.
#
#   bench/regex/gc_study/run_study.sh OUT_DIR [CASE_LIST]
set -eu
cd "$(dirname "$0")/../../.."
ROOT=$(pwd)
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$ROOT/.crystal}"
OUT=${1:?usage: run_study.sh OUT_DIR [CASE_LIST]}
CASE_LIST=${2:-bench/regex/gc_study/case_list.txt}

/usr/bin/ruby bench/regex/scripts/rebar_corpus.rb
/usr/bin/ruby bench/regex/gc_study/write_static_patterns.rb "$CASE_LIST" bench/data/regex/static_patterns.cr
BIN="$ROOT/bench/bin/regex"
mkdir -p "$BIN"
crystal-alpha build --release bench/regex/pcre2_jit_runner.cr -o "$BIN/pcre2_jit_runner"
crystal-alpha build --release bench/regex/mica_runner.cr -o "$BIN/mica_runner"
crystal-alpha build --release bench/regex/mica_static_runner.cr -o "$BIN/mica_static_runner"
crystal-alpha build --release bench/regex/run_cases.cr -o "$BIN/run_cases"
"$BIN/run_cases" --runners "$BIN" --out "$OUT" --data "$ROOT/bench/data/regex" \
  --engines pcre2-jit,mica,mica-static --corpora rebar,amber --case-list "$CASE_LIST" \
  --mica-ref "working tree ($(git rev-parse --abbrev-ref HEAD))" --mica-commit "$(git rev-parse HEAD)" \
  --harness-commit "$(git rev-parse HEAD)"
echo "results: $OUT/results.jsonl"
