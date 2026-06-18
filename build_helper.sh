#!/usr/bin/env bash
set -euo pipefail #stop on fail

# List of projects
DIRS="hol-lambdas"

# name of build script in each repo
RELEASE_BUILD="tools/complete_build.sh"
DEBUG_BUILD="tools/d_complete_build.sh"

# ---------------- Argument parsing ----------------
MODE="release"
if [ "${1-}" = "--debug" ] || [ "${1-}" = "-d" ]; then
  MODE="debug"
  shift
elif [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
  cat <<USAGE
Usage: $(basename "$0") [--debug | -d]

Runs each repo's build script sequentially and stops on any error.

  -d, --debug   Use */${DEBUG_BUILD} instead of */${RELEASE_BUILD}
  -h, --help    Show help
USAGE
  exit 0
fi

# Decide which script to run in each project directory
if [ "$MODE" = "debug" ]; then
  BUILD_SCRIPT="$DEBUG_BUILD"
else
  BUILD_SCRIPT="$RELEASE_BUILD"
fi

echo "=== Compiling projects ... ==="

for dir in $DIRS; do
  echo
  echo ">>> Entering project: $dir"
  if [ ! -d "$dir" ]; then
    echo "ERROR: Directory '$dir' not found." >&2
    exit 1
  fi

  cd "$dir"

  if [ ! -x "$BUILD_SCRIPT" ]; then
    echo "ERROR: '$BUILD_SCRIPT' not found or not executable in $dir." >&2
    exit 1
  fi

  echo "--- Running $BUILD_SCRIPT in $dir ---"
  "./$BUILD_SCRIPT"

  echo "--- Finished $dir ---"
  cd - >/dev/null
done

echo
echo "=== All builds completed ==="
