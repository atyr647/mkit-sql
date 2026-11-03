#!/bin/sh
# Two users share one temp folder (mode 1777, like /tmp).  Needs root (to become another user); skipped otherwise.
#   MKIT_MK4TCL=builtin tests/tempsec_multiuser.sh tclkit/tclkit-8.6.3
# Checks: a stranger cannot read our spill files, and a stranger's sweep never removes our abandoned folders.
[ "$(id -u)" = 0 ] || { echo "skipped: needs root"; exit 0; }
TCL=${1:?usage: $0 <tclsh or tclkit>}; TCL=$(readlink -f "$TCL")
HERE=$(cd "$(dirname "$0")" && pwd)
SHARED=$(mktemp -d); chmod 1777 "$SHARED"
OTHER=nobody; fail=0
ok() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got $2, want $3)"; fail=1; fi; }
# a script that spills (tiny budget) as the other user
cat > "$SHARED/spill.tcl" <<TCLEOF
set here $HERE
source \$here/mk4load.tcl
source \$here/loadengine.tcl
set mkitsql::tempDir $SHARED
set f $SHARED/[pid]_db.mk
set db [mkitsql::db::openFile \$f -create]
mkitsql::run "CREATE TABLE t (a INT, s TEXT)" \$db
mkitsql::run "INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d')" \$db
set mkitsql::memBytes 1 ; set mkitsql::chunk 1
mkitsql::run "SELECT s FROM t ORDER BY s DESC" \$db
puts "ROWS [llength [dict get [mkitsql::run {SELECT s FROM t ORDER BY s DESC} \$db] rows]]"
mkitsql::db::closeFile \$db
TCLEOF
chmod 644 "$SHARED/spill.tcl"; chmod -R a+rX "$HERE/.." 2>/dev/null
# root's abandoned folder (dead pid) with a spill file, and root's live statement is simulated by a fresh one
mkdir "$SHARED/mkitsql-root-999999-0123456789abcdef"; chmod 700 "$SHARED/mkitsql-root-999999-0123456789abcdef"
echo x > "$SHARED/mkitsql-root-999999-0123456789abcdef/000001.spill"
# the other user spills: its sweep must not touch root's folder, and it must not be able to read it
OUT=$(runuser -u $OTHER -- env MKIT_MK4TCL=${MKIT_MK4TCL:-} TMPDIR="$SHARED" HOME="$SHARED" "$TCL" "$SHARED/spill.tcl" 2>&1)
ok "other user's sweep leaves root's abandoned folder alone" "$([ -d "$SHARED/mkitsql-root-999999-0123456789abcdef" ] && echo kept || echo removed)" kept
ok "the other user could spill and sort in the shared folder" "$(echo "$OUT" | grep -c 'ROWS 4')" 1
# root's sweep: the other user's abandoned folder (made by us as that user) IS root's to remove (root owns nothing of it) -> must be kept
runuser -u $OTHER -- sh -c "mkdir '$SHARED/mkitsql-nobody-999998-0123456789abcdef' && chmod 700 '$SHARED/mkitsql-nobody-999998-0123456789abcdef' && echo x > '$SHARED/mkitsql-nobody-999998-0123456789abcdef/000001.spill'"
cat > "$SHARED/sweep.tcl" <<TCLEOF
set here $HERE
source \$here/mk4load.tcl
source \$here/loadengine.tcl
puts "SWEPT [mkitsql::cleanTemp $SHARED]"
TCLEOF
SW=$(MKIT_MK4TCL=${MKIT_MK4TCL:-} "$TCL" "$SHARED/sweep.tcl" 2>&1 | grep SWEPT)
ok "root removes its own abandoned folder" "$([ -d "$SHARED/mkitsql-root-999999-0123456789abcdef" ] && echo kept || echo removed)" removed
ok "root's sweep does not remove another user's abandoned folder (ownership is checked)" "$([ -d "$SHARED/mkitsql-nobody-999998-0123456789abcdef" ] && echo kept || echo removed)" kept
rm -rf "$SHARED"
exit $fail
