#!/bin/sh
# Keep tests/vendor/kitfmt (the kit reader the kit.* tests use) identical to a known commit of atyr647/ribbon's kit/kitfmt.
#
#   tests/sync-kitfmt.sh /path/to/ribbon-checkout      copy kit/kitfmt's package files and three golden kits here, and record
#                                                       the commit in tests/vendor/kitfmt/SOURCE
#   tests/sync-kitfmt.sh --check /path/to/checkout     fail unless the files here are byte for byte that commit's
#
# mkit-sql itself does not carry kitfmt (mkitsql/kit.tcl loads it with package require when a kit.* table is read): this copy
# is a test fixture, pinned like MK Studio pins mkit-sql.
set -e
cd "$(dirname "$0")/.."
DEST=tests/vendor/kitfmt
FILES="kitfmt.tcl sha256.tcl pkgIndex.tcl"
KITS="app.kit system.kit bad-chunk.kit"
if [ "$1" = "--check" ]; then
    SRC=${2:?usage: $0 --check /path/to/ribbon-checkout}
    want=$(sed -n 's/^commit //p' "$DEST/SOURCE")
    have=$(git -C "$SRC" rev-parse HEAD)
    [ "$want" = "$have" ] || { echo "checkout is at $have, SOURCE names $want"; exit 1; }
    bad=0
    for f in $FILES; do cmp -s "$SRC/kit/kitfmt/$f" "$DEST/$f" || { echo "DIFFERS: $f"; bad=1; }; done
    for k in $KITS; do cmp -s "$SRC/kit/kitfmt/tests/golden/$k" "$DEST/golden/$k" || { echo "DIFFERS: golden/$k"; bad=1; }; done
    [ $bad = 0 ] && echo "tests/vendor/kitfmt is identical to ribbon $want"
    exit $bad
fi
SRC=${1:?usage: $0 /path/to/ribbon-checkout | --check /path/to/checkout}
[ -f "$SRC/kit/kitfmt/kitfmt.tcl" ] || { echo "not a ribbon checkout: $SRC"; exit 1; }
git -C "$SRC" diff --quiet HEAD -- kit/kitfmt || { echo "the checkout has uncommitted changes in kit/kitfmt: commit them first"; exit 1; }
mkdir -p "$DEST/golden"
for f in $FILES; do cp "$SRC/kit/kitfmt/$f" "$DEST/$f"; done
for k in $KITS; do cp "$SRC/kit/kitfmt/tests/golden/$k" "$DEST/golden/$k"; done
ver=$(sed -n 's/^ *variable version \(.*\)$/\1/p' "$DEST/kitfmt.tcl" | head -1)
printf 'kitfmt %s\ncommit %s\nrepository https://github.com/atyr647/ribbon (kit/kitfmt)\n' "$ver" "$(git -C "$SRC" rev-parse HEAD)" > "$DEST/SOURCE"
echo "copied kitfmt $ver ($(git -C "$SRC" rev-parse --short HEAD)) into $DEST"
