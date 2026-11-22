#!/bin/sh
# The Deflate encoder benchmark: Mica's gzip encoder against the system
# zlib at levels 1, 6 and 9, one-shot and streaming. One command fetches
# and verifies the corpus, builds the runners with --release, runs the
# interleaved A/B rounds and writes the report:
#
#   bench/deflate_encode/run.sh                      # every corpus, levels 1, 6 and 9, 5 rounds
#   bench/deflate_encode/run.sh --quick              # Canterbury and the HTTP bodies, 3 rounds
#   bench/deflate_encode/run.sh --out DIR            # resume or extend a run directory
#   bench/deflate_encode/run.sh --corpora silesia --levels 9 --rounds 2   # one resumable piece of a long run
#   bench/deflate_encode/run.sh -- --only silesia/mozilla   # anything after -- goes to scripts/run_ab.rb
#
# The report is bench/data/deflate/encode-runs/<UTC time>/REPORT.md, with
# results.json, run.json, samples.jsonl, memory.jsonl, checks.jsonl and
# run.log beside it. See docs/benchmarks.md, "Deflate encoders".
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$ROOT/.crystal}"

OUT=""
CORPORA="canterbury,silesia,http"
LEVELS="1,6,9"
ROUNDS="5"
TITLE="Mica Deflate encoders vs system zlib benchmark"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --corpora) CORPORA=$2; shift 2 ;;
    --levels) LEVELS=$2; shift 2 ;;
    --rounds) ROUNDS=$2; shift 2 ;;
    --quick) CORPORA="canterbury,http"; ROUNDS="3"; TITLE="$TITLE (--quick)"; shift ;;
    --title) TITLE=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown option $1 (see the header of bench/deflate_encode/run.sh)" >&2; exit 2 ;;
  esac
done

# The corpus: archives downloaded and verified by sha256, extracted, and
# every input file checked against bench/deflate/corpus.tsv.
/usr/bin/ruby bench/deflate/scripts/fetch_corpus.rb

BIN="$ROOT/bench/bin/deflate_encode"
mkdir -p "$BIN"
if [ -z "$OUT" ] || [ ! -f "$OUT/run.json" ]; then
  crystal-alpha build --release bench/deflate_encode/zlib_runner.cr -o "$BIN/zlib_runner"
  crystal-alpha build --release bench/deflate_encode/mica_runner.cr -o "$BIN/mica_runner"
fi

if [ -z "$OUT" ]; then
  OUT="$ROOT/bench/data/deflate/encode-runs/$(date -u +%Y%m%dT%H%M%SZ)"
fi
/usr/bin/ruby bench/deflate_encode/scripts/run_ab.rb --bin "$BIN" --data "$ROOT/bench/data/deflate" --out "$OUT" \
  --corpora "$CORPORA" --levels "$LEVELS" --rounds "$ROUNDS" "$@"
/usr/bin/ruby bench/deflate_encode/scripts/write_report.rb --run "$OUT" --title "$TITLE"
echo "report: $OUT/REPORT.md"
