#!/bin/sh
# Build the Mk4tcl with 64-bit file positions (no 2 GiB ceiling on a database file) from the Metakit fork into a temporary directory.
# Needs: git g++ make and the Tcl development files (Debian/Ubuntu: apt install tcl8.6-dev g++ make).
#
#   tests/build_mk4tcl_wide.sh /tmp/mk4wide      # prints the library path and the env to use
#
# METAKIT_WIDE_REPO / METAKIT_WIDE_REF choose the source; the default is a COMMIT of the fork's branch, so the tests do not move under us.
# Afterwards:  MKIT_MK4TCL=<dir>/build/Mk4tclS.so tclsh tests/widefile.tcl
set -e
DIR=${1:?usage: $0 <empty build directory>}
REPO=${METAKIT_WIDE_REPO:-https://github.com/atyr647/metakit}
REF=${METAKIT_WIDE_REF:-9ffa269e70bd105d6195840bccb5759ed9a51991}
TCLINC=${TCL_INCLUDE:-/usr/include/tcl8.6}
TCLLIB=${TCL_LIBDIR:-/usr/lib/x86_64-linux-gnu}
mkdir -p "$DIR" && cd "$DIR"
if [ ! -d src ]; then
  git init -q src && cd src
  git remote add origin "$REPO"
  git fetch -q --depth 1 origin "$REF"
  git checkout -q FETCH_HEAD
  cd ..
fi
mkdir -p build && cd build
../src/unix/configure --with-tcl="$TCLINC,$TCLLIB" CC=g++ >configure.log 2>&1 || { tail -20 configure.log ; exit 1; }
make -j4 >make.log 2>&1 || { tail -30 make.log ; exit 1; }
# the Tcl binding is built against the stubs table: link it with the stubs library
g++ -shared -o Mk4tclS.so mk4tcl.o mk4too.o column.o custom.o derived.o fileio.o field.o format.o handler.o persist.o remap.o std.o store.o string.o table.o univ.o view.o viewx.o -lpthread "$TCLLIB/libtclstub8.6.a"
echo
echo "built: $PWD/Mk4tclS.so"
echo "run:   MKIT_MK4TCL=$PWD/Mk4tclS.so tclsh tests/widefile.tcl"
