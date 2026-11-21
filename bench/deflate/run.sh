#!/bin/sh
# The Inflate benchmark: Mica's raw DEFLATE, zlib and gzip decoders against
# the system zlib. One command fetches and verifies the corpus, builds the
# runners with --release, runs the interleaved A/B rounds and writes the
# report:
#
#   bench/deflate/run.sh                      # every corpus, 8 rounds (16 where an interval reaches 0.5x or 1.0x)
#   bench/deflate/run.sh --quick              # Canterbury and the HTTP bodies, 3 rounds
#   bench/deflate/run.sh --out DIR            # resume or extend a run directory
#   bench/deflate/run.sh --engines zlib-oneshot-fresh,zlib-oneshot-reused,zlib-stream,stdlib-reader   # zlib alone
#   bench/deflate/run.sh -- --only silesia/mozilla   # anything after -- goes to scripts/run_ab.rb
#
# The report is bench/data/deflate/runs/<UTC time>/REPORT.md, with
# results.json, run.json, samples.jsonl, memory.jsonl and run.log beside it.
# See docs/benchmarks.md, "Inflate".
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$ROOT/.crystal}"

OUT=""
ENGINES="mica-oneshot,zlib-oneshot-fresh,zlib-oneshot-reused,mica-stream,zlib-stream,stdlib-reader"
CORPORA="canterbury,silesia,http"
ROUNDS="--rounds 8 --max-rounds 16"
TITLE="Mica Inflate vs system zlib benchmark"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --engines) ENGINES=$2; shift 2 ;;
    --corpora) CORPORA=$2; shift 2 ;;
    --quick) CORPORA="canterbury,http"; ROUNDS="--rounds 3 --max-rounds 3"; TITLE="$TITLE (--quick)"; shift ;;
    --title) TITLE=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown option $1 (see the header of bench/deflate/run.sh)" >&2; exit 2 ;;
  esac
done

# The corpus: archives downloaded and verified by sha256, extracted, and
# every input file checked against bench/deflate/corpus.tsv.
/usr/bin/ruby bench/deflate/scripts/fetch_corpus.rb

BIN="$ROOT/bench/bin/deflate"
mkdir -p "$BIN"
crystal-alpha build --release bench/deflate/zlib_runner.cr -o "$BIN/zlib_runner"
case ",$ENGINES," in
  *,stdlib-reader,*) crystal-alpha build --release bench/deflate/stdlib_runner.cr -o "$BIN/stdlib_runner" ;;
esac
case ",$ENGINES," in
  *,mica-*) crystal-alpha build --release bench/deflate/mica_runner.cr -o "$BIN/mica_runner" ;;
esac

if [ -z "$OUT" ]; then
  OUT="$ROOT/bench/data/deflate/runs/$(date -u +%Y%m%dT%H%M%SZ)"
fi
# shellcheck disable=SC2086
/usr/bin/ruby bench/deflate/scripts/run_ab.rb --bin "$BIN" --data "$ROOT/bench/data/deflate" --out "$OUT" \
  --engines "$ENGINES" --corpora "$CORPORA" $ROUNDS "$@"
/usr/bin/ruby bench/deflate/scripts/write_report.rb --run "$OUT" --title "$TITLE"
echo "report: $OUT/REPORT.md"
