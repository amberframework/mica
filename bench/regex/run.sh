#!/bin/sh
# Builds the regex benchmark programs with --release, runs every case in
# each engine's own process, and writes the report. One command:
#
#   bench/regex/run.sh                                  # this checkout's Mica
#   bench/regex/run.sh --mica-ref origin/feature/regex-r2
#   bench/regex/run.sh --engines pcre2-jit,pcre2-interpreter --out DIR
#   bench/regex/run.sh --quick                          # smaller sizes, fewer samples
#   bench/regex/run.sh --seed 42                        # replay a recorded case order
#   bench/regex/run.sh -- --only redos/                 # anything after -- goes to the driver
#
# --mica-ref checks the ref out into a detached worktree under
# bench/data/regex/ and builds the Mica runner against that worktree's src/
# (through a generated entry file there), so the harness on this branch measures any Mica
# branch without merging. See docs/benchmarks.md.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$ROOT/.crystal}"

MICA_REF=""
OUT=""
ENGINES="pcre2-jit,pcre2-interpreter,mica"
CORPORA="rebar,amber,redos"
TITLE="Mica::Regex vs PCRE2 benchmark"
QUICK=""
SEED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mica-ref) MICA_REF=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --engines) ENGINES=$2; shift 2 ;;
    --corpora) CORPORA=$2; shift 2 ;;
    --title) TITLE=$2; shift 2 ;;
    --quick) QUICK="--max-amber-bytes 1048576 --max-samples 5 --phase-seconds 0.3 --process-cold-samples 3"; shift ;;
    --seed) SEED="--seed $2"; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown option $1 (see the header of bench/regex/run.sh)" >&2; exit 2 ;;
  esac
done

# The rebar corpus: fetched at the pinned commit, verified by sha256, and
# converted to rebar.json under bench/data/regex/rebar-<commit>/.
/usr/bin/ruby bench/regex/scripts/rebar_corpus.rb

if [ -n "$MICA_REF" ]; then
  git fetch --quiet origin || echo "git fetch failed; using local refs" >&2
  MICA_COMMIT=$(git rev-parse --verify "$MICA_REF^{commit}")
  MICA_WORKTREE="$ROOT/bench/data/regex/mica-$MICA_COMMIT"
  if [ ! -d "$MICA_WORKTREE" ]; then
    git worktree add --detach "$MICA_WORKTREE" "$MICA_COMMIT"
  fi
  MICA_ENTRY="$ROOT/bench/data/regex/mica_runner_$MICA_COMMIT.cr"
  # Crystal requires are relative, so the entry sits beside the worktree.
  printf '%s\n' "require \"./mica-$MICA_COMMIT/src/mica\"" 'require "../../regex/src/mica_runner_body"' > "$MICA_ENTRY"
else
  MICA_REF="working tree ($(git rev-parse --abbrev-ref HEAD))"
  MICA_COMMIT=$(git rev-parse HEAD)
  MICA_ENTRY="bench/regex/mica_runner.cr"
fi

BIN="$ROOT/bench/bin/regex"
mkdir -p "$BIN"
crystal-alpha build --release bench/regex/pcre2_jit_runner.cr -o "$BIN/pcre2_jit_runner"
crystal-alpha build --release bench/regex/pcre2_interpreter_runner.cr -o "$BIN/pcre2_interpreter_runner"
crystal-alpha build --release "$MICA_ENTRY" -o "$BIN/mica_runner"
crystal-alpha build --release bench/regex/run_cases.cr -o "$BIN/run_cases"
crystal-alpha build --release bench/regex/write_report.cr -o "$BIN/write_report"

if [ -z "$OUT" ]; then
  OUT="$ROOT/bench/data/regex/runs/$(date -u +%Y%m%dT%H%M%SZ)"
fi
# shellcheck disable=SC2086
"$BIN/run_cases" --runners "$BIN" --out "$OUT" --data "$ROOT/bench/data/regex" \
  --engines "$ENGINES" --corpora "$CORPORA" --mica-ref "$MICA_REF" --mica-commit "$MICA_COMMIT" \
  --harness-commit "$(git rev-parse HEAD)" $QUICK $SEED "$@"
"$BIN/write_report" --run "$OUT" --title "$TITLE"
echo "report: $OUT/REPORT.md"
