#!/bin/sh
# The digest of tests/listbug.tcl must be the same on every Tcl and at every memory budget.
#   sh tests/listbug.sh  <reference tclsh with the mock>  <tclkit> [<tclkit>...]
here=$(dirname "$0") ; ref=$1 ; shift
want=$("$ref" "$here/listbug.tcl" 2>&1 | grep -v "^(")
case "$want" in *"while executing"*|"") echo "reference run failed:"; echo "$want" | cut -c1-200 | head -5; exit 2;; esac
rc=0
"$ref" "$here/listbug_forms.tcl" dump /tmp/listbug_canon.$$ || exit 2
for kit in "$@"; do
    MKIT_MK4TCL=builtin "$kit" "$here/listbug_forms.tcl" check /tmp/listbug_canon.$$ || rc=1
    for budget in "" "MKIT_MEMBYTES=20000 MKIT_CHUNK=3" "MKIT_MEMBYTES=3000 MKIT_CHUNK=1" "MKIT_CHUNK=2" "MKIT_MEMBYTES=1000 MKIT_CHUNK=7" "MKIT_BULKMIN=1 MKIT_MEMBYTES=2000 MKIT_CHUNK=2" "MKIT_BULKMIN=1 MKIT_PUSHMIN=1" "MKIT_BULKMIN=1 MKIT_MEMBYTES=1000 MKIT_CHUNK=5 MKIT_PUSHMIN=1"; do
        got=$(env $budget MKIT_MK4TCL=builtin "$kit" "$here/listbug.tcl" 2>&1 | grep -v '^(')
        if [ "$got" = "$want" ]; then echo "ok   $kit  $budget"; else echo "DIFF $kit  $budget"; echo "$got" > /tmp/listbug_got.txt; echo "$want" > /tmp/listbug_want.txt; rc=1; fi
    done
done
rm -f /tmp/listbug_canon.$$
exit $rc
