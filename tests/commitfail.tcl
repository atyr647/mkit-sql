# A failing commit (a file-size limit stands in for a full disk and Metakit's 2 GiB limit; Linux, needs `prlimit`) must leave the
# database exactly as it was at the last commit, with a usable handle, on both storage layers; plus the leftovers of commit records.
#   tclkit tests/commitfail.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" } }
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set exe [info nameofexecutable]
if {$::tcl_platform(platform) eq "unix" && ![catch {exec prlimit --version}]} {
    foreach backend {standalone studio} {
        foreach limit {30000 120000} {
            set f $tmp/mkitsql_cf_[pid]_$backend$limit.mk ; file delete $f
            set out [exec env MKIT_BACKEND=$backend MKIT_MK4TCL=builtin prlimit --fsize=$limit sh -c {trap "" XFSZ; exec "$@"} sh $exe $here/commitfail_child.tcl $f 2>@1]
            regexp {RESULT code=(.*) committed=(\d+) rows_after=(\d+) pending=(\d+) recordLeft=(\d)} $out -> code committed rows pending left
            check "$backend/$limit: the failure is reported as COMMITFAILED" [lindex [lindex $code 0] 1] COMMITFAILED
            check "$backend/$limit: rows are the committed ones" $rows $committed
            check "$backend/$limit: nothing pending" $pending 0
            check "$backend/$limit: no record left" $left 0
            # a fresh process (no limit) reads the file back
            set back [exec env MKIT_BACKEND=$backend MKIT_MK4TCL=builtin $exe $here/bigfile_child.tcl $f 2>@1]
            check "$backend/$limit: reopened without the limit" [lindex [split [string trim $back] "\n"] end] "$committed rows $committed"
            file delete $f ; file delete $f.commit ; file delete $f.lock
        }
    }
} else { puts "(no prlimit here: the failing-commit part is skipped)" }
# leftovers of commit records (standalone layer; this part loads db.tcl itself)
set out [exec env MKIT_BACKEND=standalone MKIT_MK4TCL=builtin $exe $here/commitfail_records.tcl 2>&1]
puts $out
regexp {records: (\d+) passed, (\d+) failed} $out -> p2 f2
incr pass $p2 ; incr fail $f2
puts "pass $pass fail $fail"
exit [expr {$fail ? 1 : 0}]
