#!/bin/sh
# Download the tclkit runtimes MK Studio ships on (the ones that contain the Mk4tcl you will actually
# use), verifying each against its published SHA1, into ./tclkit/.
#   tests/fetch-tclkit.sh            Linux x86_64 (the default)
#   tests/fetch-tclkit.sh windows    tclkit/tclkit-8.6.3.exe and tclkit-8.5.17.exe (win32 x86_64)
#   tests/fetch-tclkit.sh macos      tclkit/tclkit-8.6.3 and tclkit-8.5.17 (macOS universal ix86+x86_64)
# then:  MKIT_MK4TCL=builtin tclkit/tclkit-8.5.17 tests/run.tcl
set -e
cd "$(dirname "$0")/.." && mkdir -p tclkit
BASE=https://tclkits.rkeene.org/fossil/raw
sha() { if command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | cut -d' ' -f1; else shasum -a 1 "$1" | cut -d' ' -f1; fi; }
get() {  # local-name remote-name sha1
    out=tclkit/$1
    if [ -f "$out" ] && [ "$(sha "$out")" = "$3" ]; then echo "ok      $1"; return; fi
    curl -fsSL --retry 3 -o "$out.part" "$BASE/$2?name=$3"
    got=$(sha "$out.part")
    if [ "$got" != "$3" ]; then rm -f "$out.part"; echo "SHA1 mismatch for $1 (got $got)"; exit 1; fi
    mv "$out.part" "$out"; chmod +x "$out"; echo "fetched $1"
}
case "${1:-linux}" in
    linux)
        get tclkit-8.6.3 tclkit-8.6.3-rhel5-x86_64 36b5cb68899cfcb79417a29f9c6d8176ebae0d24
        get tclkit-8.5.17 tclkit-8.5.17-rhel5-x86_64 76a197fe41359daaf4f90a2001f46675b3667e26 ;;
    windows)
        get tclkit-8.6.3.exe tclkit-8.6.3-win32-x86_64.exe 403c507437d0b10035c7839f22f5bb806ec1f491
        get tclkit-8.5.17.exe tclkit-8.5.17-win32-x86_64.exe 6b30a5fa6330ab8c56dda7f4b44e7491fbcf0718 ;;
    macos)
        get tclkit-8.6.3 tclkit-8.6.3-macosx10.5-ix86+x86_64 1b4a7ae47ebab6ea9e0e16af4d8714c8b4aa0ce2
        get tclkit-8.5.17 tclkit-8.5.17-macosx10.5-ix86+x86_64 2a19c5c86561c1415ec4a4a70483de8608fb48d9 ;;
    *) echo "usage: $0 [linux|windows|macos]" ; exit 2 ;;
esac
