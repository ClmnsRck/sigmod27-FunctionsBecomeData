#!/usr/bin/env bash
# Build the engine (hol-lambdas/) from scratch: PostgreSQL 17.4 with the lambda
# extension, installed into hol-lambdas/install/, plus the operators in src/ext.
#
#   ./build_helper.sh            release build (-O2), what the benchmarks use
#   ./build_helper.sh --debug    debug build (-Og, assertions)
#
# The build ends with a short initdb/start/stop of a test cluster on $PGPORT
# (default here: 5433, so it does not collide with a system PostgreSQL on 5432).
set -euo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hol-lambdas"
BUILD_SCRIPT="tools/complete_build.sh"

case "${1-}" in
  -d|--debug) BUILD_SCRIPT="tools/d_complete_build.sh" ;;
  -h|--help)  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")         ;;
  *)          echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

export PGPORT="${PGPORT:-5433}"

cd "$ENGINE"

# archives (e.g. a zip download) can drop the executable bits
chmod +x configure tools/*.sh

# The build script starts with `make clean`, which needs a configured tree. A fresh
# checkout (or one after `make distclean`) has none, so configure it once without
# options first; the build script then configures it properly.
if [ ! -f src/Makefile.global ]; then
  echo "=== tree not configured yet: running a plain ./configure first ==="
  ./configure
fi

echo "=== $BUILD_SCRIPT ==="
"./$BUILD_SCRIPT"

echo "=== build done: $ENGINE/install ==="
