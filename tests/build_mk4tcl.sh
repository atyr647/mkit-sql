#!/bin/sh
# Build the real Metakit + Mk4tcl (Tcl 8.6) into a temporary directory so the test suite
# can run against it.  Needs: git cmake g++ and the Tcl development files
# (Debian/Ubuntu: apt install tcl8.6-dev cmake g++).
#
#   tests/build_mk4tcl.sh /tmp/mk4build      # prints the library path and the env to use
#
# Afterwards:  LD_LIBRARY_PATH=<dir>/build/src MKIT_MK4TCL=<dir>/build/tcl/libMk4tcl.so tclsh tests/run.tcl
set -e
DIR=${1:?usage: $0 <empty build directory>}
mkdir -p "$DIR" && cd "$DIR"
[ -d metakit ] || git clone --depth 1 https://github.com/tcltk/metakit metakit
mkdir -p build && cd build
cmake ../metakit -DMETAKIT_PYTHON=OFF -DCMAKE_BUILD_TYPE=Release
make -j4 mk4_shared
# the Tcl binding's CMake asks for -lmk4 but the library is built as libmk4_shared
ln -sf "$PWD/src/libmk4_shared.so" "$PWD/src/libmk4.so"
LIBRARY_PATH="$PWD/src" make Mk4tcl
echo
echo "built: $PWD/tcl/libMk4tcl.so"
echo "run:   LD_LIBRARY_PATH=$PWD/src MKIT_MK4TCL=$PWD/tcl/libMk4tcl.so tclsh tests/run.tcl"
