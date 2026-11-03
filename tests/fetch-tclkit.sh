#!/bin/sh
# Download the tclkit runtimes MK Studio ships on (the ones that contain the Mk4tcl you will actually
# use), verifying each against its published SHA1, into ./tclkit/.
#   tests/fetch-tclkit.sh
# then:  MKIT_MK4TCL=builtin tclkit/tclkit-8.5.17 tests/run.tcl
set -e
cd "$(dirname "$0")/.." && mkdir -p tclkit
BASE=https://tclkits.rkeene.org/fossil/raw
get() {  # local-name remote-name sha1
    out=tclkit/$1
    if [ -f "$out" ] && [ "$(sha1sum "$out" | cut -d' ' -f1)" = "$3" ]; then echo "ok      $1"; return; fi
    curl -fsSL --retry 3 -o "$out.part" "$BASE/$2?name=$3"
    got=$(sha1sum "$out.part" | cut -d' ' -f1)
    if [ "$got" != "$3" ]; then rm -f "$out.part"; echo "SHA1 mismatch for $1 (got $got)"; exit 1; fi
    mv "$out.part" "$out"; chmod +x "$out"; echo "fetched $1"
}
get tclkit-8.6.3 tclkit-8.6.3-rhel5-x86_64 36b5cb68899cfcb79417a29f9c6d8176ebae0d24
get tclkit-8.5.17 tclkit-8.5.17-rhel5-x86_64 76a197fe41359daaf4f90a2001f46675b3667e26
