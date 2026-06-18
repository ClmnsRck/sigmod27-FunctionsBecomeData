#Shell Setup steps
set -e
MY_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "Using ROOT_DIR: $MY_ROOT_DIR"
pushd "$MY_ROOT_DIR"

#First, clean up
make clean
[ -d pgdata ] && rm -rf pgdata/*
[ -d install ] && rm -rf install/*

#setup project
./configure --with-llvm --prefix="$MY_ROOT_DIR/install" CFLAGS='-fopenmp -Wno-ignored-attributes' CXXFLAGS='-lpthread -lpq -lm -fopenmp'

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

#This script builds the entirety of the project from scratch, however, due to the configure script being needed for a "make clean"
#make sure you ran a naked "./configure" atleast once