#!/bin/bash
# PT-BR WER + latency benchmark for every downloaded Portuguese-capable model.
#
# Usage:
#   scripts/benchmark-ptbr.sh <clips-dir> [variant1,variant2,...]
#
# <clips-dir> holds name.wav|name.m4a + name.txt pairs (see docs/BENCHMARK.md).
# Results print to the console and are written to build/benchmark-ptbr-<ts>.md.
# Override the derived data path with DERIVED_DATA_PATH=... if needed.

set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <clips-dir> [comma-separated-model-variants]" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -d "$1" ]; then
  echo "Error: clips directory not found: $1" >&2
  exit 66
fi
BENCH_DIR="$(cd "$1" && pwd)"
MODELS="${2:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/build/bench-derived}"
LOG="$ROOT/build/benchmark-ptbr-xcodebuild.log"
OUT="${SPEAKTYPE_BENCH_OUT:-$ROOT/build/benchmark-ptbr-$(date +%Y%m%d-%H%M%S).md}"
mkdir -p "$ROOT/build"

# Seed from the local build cache (clonefile, near-free) so the first run
# doesn't re-resolve and rebuild every Swift package from scratch.
if [ ! -d "$DERIVED_DATA_PATH" ] && [ -d "$ROOT/build/local-derived" ]; then
  cp -cR "$ROOT/build/local-derived" "$DERIVED_DATA_PATH" 2>/dev/null || true
fi

echo "Clips:  $BENCH_DIR"
echo "Models: ${MODELS:-all downloaded PT-capable models}"
echo "Log:    $LOG"
echo "Report: $OUT"

# xcodebuild forwards TEST_RUNNER_<VAR> to the test process as <VAR>.
set +e
TEST_RUNNER_SPEAKTYPE_BENCH_DIR="$BENCH_DIR" \
TEST_RUNNER_SPEAKTYPE_BENCH_MODELS="$MODELS" \
TEST_RUNNER_SPEAKTYPE_BENCH_OUT="$OUT" \
xcodebuild test \
  -project speaktype.xcodeproj \
  -scheme speaktype \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:speaktypeTests/PTBRBenchmarkTests/testPortugueseBenchmark \
  CODE_SIGNING_ALLOWED=NO \
  > "$LOG" 2>&1
STATUS=$?
set -e

# The hosted test's stdout isn't captured by xcodebuild, so show the report file.
grep -E "error:|skipped|\*\* TEST" "$LOG" | tail -5 || true
if [ -f "$OUT" ]; then
  echo
  cat "$OUT"
  echo
  echo "Report: $OUT"
elif [ $STATUS -eq 0 ]; then
  echo "No report written — the test was skipped (no clips or no downloaded PT models)." >&2
fi

if [ $STATUS -ne 0 ]; then
  echo "xcodebuild failed (exit $STATUS); see $LOG" >&2
fi
exit $STATUS
