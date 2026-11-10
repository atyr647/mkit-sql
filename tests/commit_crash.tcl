# A commit that stops at each named step (the commitHook of db.tcl): the next writer must find the database as it was before the
# commit (50 rows) when the commit had not yet been made safe, and with the commit (75 rows) when it had - never anything between, never
# a refusal, never a record left behind.  Three ways to stop:
#   child kill    a process that exits at the step: the operating system keeps every write it made
#   child power   the same, and the commit record is put into what tests/commit_model.tcl says was durable (a deletion that was never
#                 flushed comes back).  The database file is taken as written: reordering inside a commit is tests/power_loss.tcl's job
#   raise         the hook raises an error in this process, the handle is dropped
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/commit_crash.tcl
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/mkutil.tcl
# the stand-in Mk4tcl writes files with no Metakit header, so no commit record describes them and a commit has no steps after the commit itself
if {$::mk4kind eq "stand-in"} { puts "skipped: needs a real Mk4tcl" ; exit 0 }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 200]\n  want: [string range $want 0 200]"} }
set area [tmp mkitsql_crash_[pid]] ; file delete -force $area ; file mkdir $area
set f $area/c.mk ; set rec $f.commit
set exe [info nameofexecutable]
proc clean {} { foreach x [glob -nocomplain $::f $::f.*] { file delete -force $x } }
proc prepare {} {
    clean
    set db [mkitsql::db::openFile $::f -create]
    mkitsql::db::createView $db t {{k I {}}}
    for {set i 0} {$i < 50} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    mkitsql::db::closeFile $db
}
# the next writer: rows it finds, then it makes one more commit (which must work and leave no litter), and a reader sees the rows
proc afterwards {name want} {
    set t [mkitsql::db::openFile $::f]
    check "$name: rows the next writer finds" [mkitsql::db::size $t.t] $want
    check "$name: no commit record left by the open" [file exists $::rec] 0
    mkitsql::db::appendRow $t.t k 999
    mkitsql::db::commit $t
    mkitsql::db::closeFile $t
    check "$name: a later commit leaves no record" [file exists $::rec] 0
    check "$name: ... and no temporary record" [file exists $::rec.tmp] 0
    set t [mkitsql::db::openFile $::f -readonly]
    check "$name: a reader sees the later commit" [mkitsql::db::size $t.t] [expr {$want + 1}]
    mkitsql::db::closeFile $t
}
# step -> rows after the crash.  record-rewritten is the first point where the commit is safe on its own.
set steps {start 50 record-written 50 committed 50 data-synced 50 record-tmp-written 50 record-rewritten 75 record-deleted 75 checksum-written 75}

foreach {step want} $steps {
    foreach mode {kill power} {
        prepare
        set rc [catch {exec $exe $here/commit_crash_child.tcl $f $step $mode 2>@1} out opts]
        check "$step/$mode: the child stopped at the step" [expr {$rc ? [list [lindex [dict get $opts -errorcode] 0] [lindex [dict get $opts -errorcode] 2]] : "it did not stop"}] {CHILDSTATUS 42}
        afterwards "$step/$mode" $want
    }
}
# the hook raises an error: whatever the commit had done stays done
proc raiseAt {name} { if {$name eq $::raiseStep} { error "stop at $name" } }
foreach {step want} $steps {
    prepare
    set ::raiseStep $step
    set t [mkitsql::db::openFile $f]
    for {set i 50} {$i < 75} {incr i} { mkitsql::db::appendRow $t.t k $i }
    set mkitsql::db::commitHook raiseAt
    check "$step/raise: the commit reports the stop" [catch {mkitsql::db::commit $t} msg] 1
    set mkitsql::db::commitHook ""
    mkitsql::db::closeFile $t
    afterwards "$step/raise" $want
}
# a commit that is not stopped goes through every step, in this order, and leaves one finished database
prepare
set ::seen {}
proc note {name} { lappend ::seen $name }
set t [mkitsql::db::openFile $f]
for {set i 50} {$i < 75} {incr i} { mkitsql::db::appendRow $t.t k $i }
set mkitsql::db::commitHook note
mkitsql::db::commit $t
set mkitsql::db::commitHook ""
mkitsql::db::closeFile $t
check "the steps of a whole commit" $::seen [dict keys $steps]
afterwards "whole commit" 75
file delete -force $area
puts "commit crash: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
