#!/bin/sh
# Put mkit-sql behind MK Studio's query window.
#
#   integration/install-into-mkstudio.sh /path/to/mkstudio-checkout
#
# - copies the engine into  mkstudio.vfs/lib/mkitsql/   (so it is part of the starpack)
# - applies integration/mkstudio.patch:  loader.tcl loads mkit-sql instead of the built-in dialect,
#   the sample script uses LIMIT, the explorer refreshes after MERGE, dropping a view discards its rows
#
# The patch is plain `git diff` output; review it with  cat integration/mkstudio.patch
set -e
MK=${1:?usage: $0 /path/to/mkstudio}
HERE=$(cd "$(dirname "$0")/.." && pwd)
[ -d "$MK/mkstudio.vfs/lib/app-mkstudio" ] || { echo "not a mkstudio checkout: $MK"; exit 1; }
# MK Studio now carries mkit-sql itself (mkstudio.vfs/lib/mkitsql, kept in step by its tools/sync-mkitsql.sh): then there is nothing to
# patch, and the engine files are simply refreshed to this checkout's.
if [ -f "$MK/mkstudio.vfs/lib/mkitsql/SOURCE" ]; then
    echo "this MK Studio already has mkit-sql integrated ($(head -1 "$MK/mkstudio.vfs/lib/mkitsql/SOURCE")); use its tools/sync-mkitsql.sh to update the copy"
    exit 0
fi
mkdir -p "$MK/mkstudio.vfs/lib/mkitsql"
cp "$HERE"/mkitsql/*.tcl "$MK/mkstudio.vfs/lib/mkitsql/"
( cd "$MK" && git apply --check "$HERE/integration/mkstudio.patch" && git apply "$HERE/integration/mkstudio.patch" )
echo "installed.  Test it:  cd $MK && tclsh tests/lint.tcl && xvfb-run -a wish tests/gui_logic.tcl"
