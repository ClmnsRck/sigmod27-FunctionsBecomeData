#Shell Setup steps
set -e
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "Using ROOT_DIR: $ROOT_DIR"
pushd "$ROOT_DIR"

#build everything and install
make -j"$(nproc)"
make install

#build and install ext_functions
cd src/ext/
make install-postgres-bitcode install-postgres-shlibs
cd ../..

#setup and run postgres
[ -d pgdata ] && rm -rf pgdata/*
install/bin/initdb -D pgdata/
install/bin/pg_ctl -D pgdata/ -l pgdata/logfile start -w
install/bin/createdb test
install/bin/pg_ctl -D pgdata stop

popd