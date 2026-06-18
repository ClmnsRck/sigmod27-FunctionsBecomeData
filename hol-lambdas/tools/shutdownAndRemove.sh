#Shell Setup steps
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "Using ROOT_DIR: $ROOT_DIR"
pushd "$ROOT_DIR"

#shutdown postgres and delete DB-data
install/bin/pg_ctl -D pgdata stop
[ -d pgdata ] && rm -rf pgdata/*

#Remove all build files and delete all binaries, etc.
make clean
[ -d install ] && rm -rf install/*

popd

