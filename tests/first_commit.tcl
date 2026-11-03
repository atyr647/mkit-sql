# The first commit of a new database, interrupted at every Nth write (strace fault injection): the next writer must find a new, EMPTY
# database (the record says "empty 0"), never a refusal, never partial data.  Linux with strace only.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/first_commit.tcl
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 200]\n  want: [string range $want 0 200]"} }
if {[catch {exec strace -V}] || $::tcl_platform(os) ne "Linux"} { puts "skipped: needs strace on Linux" ; exit 0 }
set kit [info nameofexecutable]
set area [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_firstcommit_[pid]
file delete -force $area ; file mkdir $area ; set f $area/n.mk
proc clean {} { global f ; foreach x [glob -nocomplain $f $f.*] { file delete -force $x } }
# a complete run: nothing left but the database, and it holds the data
clean ; exec $kit $here/first_commit_child.tcl $f
check "complete: no record left" [file exists $f.commit] 0
set t [mkitsql::db::openFile $f -readonly]
check "complete: the data" [mkitsql::db::size $t.items] 300
mkitsql::db::closeFile $t
# the write count of a complete run, then kill at points all the way through it
set outcomes [dict create]
foreach N {1 2 3 4 5 6 7 8 10 12 15 20 30 50} {
    clean
    catch {exec strace -f -qq -P $f -e trace=write -e inject=write:signal=SIGKILL:when=$N -o /dev/null $kit $here/first_commit_child.tcl $f 2>/dev/null}
    set had [file exists $f]
    # whatever it left, the next WRITER must open it as a new empty database or as the finished one - never refuse, never partial
    set rc [catch {mkitsql::db::openFile $f} t msg]
    if {$rc} { check "kill at write $N: opens" $t "a database" ; continue }
    set n [expr {[lsearch -exact [mkitsql::db::views $t] items] >= 0 ? [mkitsql::db::size $t.items] : -1}]
    set state [expr {$n == 300 ? "NEW" : ($n == -1 ? "EMPTY" : "PARTIAL($n)")}]
    dict incr outcomes $state
    check "kill at write $N: empty or complete, never partial ($state)" [expr {$state in {NEW EMPTY}}] 1
    mkitsql::db::closeFile $t
    check "kill at write $N: no record left behind" [file exists $f.commit] 0
}
puts "  outcomes of the interrupted first commit: $outcomes"
check "at least one kill really interrupted the commit" [expr {[dict exists $outcomes EMPTY]}] 1
file delete -force $area
puts "first commit: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
