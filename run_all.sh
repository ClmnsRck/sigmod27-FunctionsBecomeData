#!/usr/bin/env bash
#
# One entry point for the paper's measurements: generate -> benchmark (grid slices +
# core sweep) -> equivalence -> use case -> report -> figure CSVs. Every stage is
# recorded; a failure anywhere makes the run exit non-zero and say so at the end.
#
#   ./run_all.sh                       the paper's run (all blobs, -r 20, round robin)
#   ./run_all.sh --smoke               shape check: blobs 1 and 4, 1 repeat, all stages
#   ./run_all.sh --topology local      on a machine with fewer than 36 CPUs
#
# Set ENV_SETUP=<file> to have a shell file sourced first (e.g. one that puts LLVM
# and the Python venv with psycopg/pandas on PATH).
#
set -uo pipefail

MODE=full
TOPOLOGY="server"
REPEATS=""
BLOB=""
STRICT_WORKERS=0
SKIP_EQUIV=0
SKIP_USECASE=0

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  cat <<USAGE

  --smoke              blobs 1 and 4 (slices: 10k and 40k x 100; sweep: widths 1 and 8),
                       use-case blob 1, 1 repeat
  --topology T         server (default) | local
  -r, --repeats N      measured runs per blob (default 20; 2 warmups always run on top)
  --blob SPEC          '5', '3-7', '1,4,9-12' (main suite)
  --strict-workers     abort a type as soon as a blob misses its width or plan
                       (default: record it, finish the type, exit non-zero)
  --skip-equivalence   don't run the equivalence check
  --skip-usecase       don't run the use case
USAGE
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --smoke)            MODE=smoke; shift ;;
    --full)             MODE=full; shift ;;
    --topology)         TOPOLOGY="$2"; shift 2 ;;
    -r|--repeats)       REPEATS="$2"; shift 2 ;;
    --blob)             BLOB="$2"; shift 2 ;;
    --strict-workers)   STRICT_WORKERS=1; shift ;;
    --skip-equivalence) SKIP_EQUIV=1; shift ;;
    --skip-usecase)     SKIP_USECASE=1; shift ;;
    -h|--help)          usage ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  smoke) : "${BLOB:=1,4}"; : "${REPEATS:=1}" ;;
esac

cd "$(dirname "$0")"
ROOT="$PWD"

# ---------------------------------------------------------------- environment
if [ -n "${ENV_SETUP:-}" ]; then
  # shellcheck disable=SC1090
  source "$ENV_SETUP"
fi

PG="$ROOT/hol-lambdas/install/bin/postgres"
if [ ! -x "$PG" ]; then
  echo "FATAL: no build at $PG -- run ./build_helper.sh first" >&2
  exit 1
fi
python3 -c "import psycopg" 2>/dev/null || { echo "FATAL: python module psycopg missing" >&2; exit 1; }
HAVE_PANDAS=1
python3 -c "import pandas" 2>/dev/null || { HAVE_PANDAS=0; echo "WARNING: python module pandas missing -- the figure CSVs are skipped" >&2; }

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$ROOT/bench_logs/run_all_$STAMP"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.txt"
# result directories newer than this belong to this run
START_MARK="$LOG_DIR/.started"
touch "$START_MARK"

FAILED=()
stage() {
  local name="$1"; shift
  echo "=== [$name] $* ==="
  local t0 t1
  t0=$(date +%s)
  if "$@" >>"$LOG_DIR/$name.log" 2>&1; then
    t1=$(date +%s)
    echo "  ok  ($((t1-t0))s)  -> $LOG_DIR/$name.log"
    echo "ok    $name  $((t1-t0))s" >>"$SUMMARY"
  else
    local rc=$?
    t1=$(date +%s)
    echo "  FAIL rc=$rc ($((t1-t0))s) -> $LOG_DIR/$name.log"
    tail -15 "$LOG_DIR/$name.log" | sed 's/^/    | /'
    echo "FAIL  $name  rc=$rc" >>"$SUMMARY"
    FAILED+=("$name")
  fi
}

echo "run_all  mode=$MODE  topology=$TOPOLOGY  blob=${BLOB:-all}  repeats=${REPEATS:-default}"
echo "logs     $LOG_DIR"
echo

# ------------------------------------------------------------------- generate
# into a directory cleared of old blobs, so no stale benchmark_*.sql can be read
stage generate bash -c "rm -f benchmarks/benchmark_*.sql && python3 generate_benchmarks.py && python3 generate_usecase_benchmarks.py"

# ------------------------------------------------------------------ benchmark
ARGS=(--topology "$TOPOLOGY")
[ -n "$REPEATS" ] && ARGS+=(-r "$REPEATS")
[ "$STRICT_WORKERS" -eq 1 ] && ARGS+=(--strict-workers)
BENCH_ARGS=("${ARGS[@]}")
[ -n "$BLOB" ] && BENCH_ARGS+=(--blob "$BLOB")
stage benchmark python3 benchmark.py "${BENCH_ARGS[@]}"
RUN_DIR="$(find "$ROOT/results" -maxdepth 1 -name 'bench_*' -type d -newer "$START_MARK" 2>/dev/null | sort | tail -1)"

# ---------------------------------------------------------------- equivalence
[ "$SKIP_EQUIV" -eq 0 ] && stage equivalence python3 additional-tests/equivalence/run_equivalence.py

# ------------------------------------------------------------------- use case
# same cluster directory and port as the main suite, so it runs after it
UC_DIR=""
if [ "$SKIP_USECASE" -eq 0 ]; then
  UC_ARGS=("${ARGS[@]}")
  [ "$MODE" = "smoke" ] && UC_ARGS+=(--blob 1)
  stage usecase python3 run_usecase_benchmark.py "${UC_ARGS[@]}"
  UC_DIR="$(find "$ROOT/results" -maxdepth 1 -name 'usecase_*' -type d -newer "$START_MARK" 2>/dev/null | sort | tail -1)"
fi

# ------------------------------------------------------- report + figure CSVs
if [ -n "$RUN_DIR" ]; then
  stage report python3 report.py "$RUN_DIR" ${UC_DIR:+"$UC_DIR"}
  PUB_ARGS=("$(basename "$RUN_DIR")")
  [ -n "$UC_DIR" ] && PUB_ARGS+=(--usecase-run "$(basename "$UC_DIR")")
  if [ "$HAVE_PANDAS" -eq 1 ]; then
    stage figures python3 results/publish_to_paper.py "${PUB_ARGS[@]}"
  else
    echo "  skip figures -- needs pandas: python3 results/publish_to_paper.py ${PUB_ARGS[*]}"
    echo "skip  figures  (no pandas)" >>"$SUMMARY"
  fi
else
  echo "  skip report -- benchmark produced no results directory"
  echo "FAIL  report  no results dir" >>"$SUMMARY"
  FAILED+=(report)
fi

# --------------------------------------------------------------------- verdict
echo
echo "================ summary ================"
cat "$SUMMARY" 2>/dev/null
[ -n "$RUN_DIR" ] && echo "results:     $RUN_DIR"
[ -n "$UC_DIR" ] && echo "use case:    $UC_DIR"
[ -n "$RUN_DIR" ] && [ "$HAVE_PANDAS" -eq 1 ] && echo "figure CSVs: $ROOT/results/paper_csv/$(basename "$RUN_DIR")"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "FAILED STAGES: ${FAILED[*]}"
  exit 1
fi
echo "all stages ok"
