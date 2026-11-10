# The real Metakit fork's write lock and stale-commit check, with real processes:
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/metakit_lock.tcl
# Skipped where this Mk4tcl has no such lock (found by trying: a second raw writer must be refused with errorcode {MK LOCKED}).
# What is checked: a writer holds the file, a second one - through mkit-sql, and from a program that ignores mkit-sql's lock file - gets the
# clear {MKIT LOCKED} error; a reader is not kept out; a killed holder leaves nothing behind; a program that left the lock out and
# committed first makes mkit-sql's COMMIT say {MKIT CHANGED}, write nothing, keep the other program's rows, and work again after ROLLBACK;
# mkit-sql's own second handle on one file (a hard link, the only way past its path check) is refused cleanly.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/mkutil.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 300]\n  want: [string range $want 0 300]"} }
set area [tmp mkitsql_mklock_[pid]] ; file delete -force $area ; file mkdir $area
set f $area/l.mk
# is there a lock?
set probe $area/probe.mk
mk::file open pa $probe ; mk::view layout pa.t {k:I} ; mk::file commit pa
set ::errorCode NONE
set locked [catch {mk::file open pb $probe} msg] ; set code $::errorCode
catch {mk::file close pb} ; mk::file close pa
if {!$locked || [lrange $code 0 1] ne {MK LOCKED}} {
    puts "skipped: this Mk4tcl has no write lock (second writer: [expr {$locked ? $code : {allowed}}])"
    file delete -force $area ; exit 0
}
set exe [info nameofexecutable]
proc clean {} { foreach x [glob -nocomplain $::f $::f.* $::area/l.lnk*] { file delete -force $x } }
proc prepare {} {
    clean
    set db [mkitsql::db::openFile $::f -create]
    mkitsql::db::createView $db t {{k I {}}}
    for {set i 0} {$i < 10} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    mkitsql::db::closeFile $db
}
proc child {args} {
    set rc [catch {exec $::exe $::here/metakit_lock_child.tcl {*}$args 2>@1} out opts]
    return [list $rc $out [expr {$rc ? [dict get $opts -errorcode] : ""}]]
}
proc result {r} { return [lindex [split [string trim [lindex $r 1]] \n] end] }
proc rows {db} { return [lindex [dict get [mkitsql::run "SELECT COUNT(*) FROM t" $db] rows] 0 0] }
proc rawRows {} { mk::file open rr $::f -readonly ; set n [mk::view size rr.t] ; mk::file close rr ; return $n }
proc waitFor {p} { for {set i 0} {$i < 300 && ![file exists $p]} {incr i} { after 50 } ; return [file exists $p] }

# ---- one process holds the file ----
prepare
set ready $area/ready ; file delete $ready $ready.go
set holder [exec $exe $here/metakit_lock_child.tcl hold $f $ready 2>@1 &]
check "a holder is up" [waitFor $ready] 1
check "plain Mk4tcl, second writer: {MK LOCKED}" [lrange [lindex [result [child raw-open $f]] 1] 0 1] {MK LOCKED}
set r [result [child open $f]]
check "mkit-sql, second writer: refused by its own lock file first" [lrange [lindex $r 1] 0 1] {MKIT LOCKED}
set r [result [child open-bare $f]]
check "mkit-sql from a program that ignores the lock file: Metakit's lock, as {MKIT LOCKED}" [lindex $r 1] {MKIT LOCKED 0 unknown {} {}}
check "... with a message that says what to do" [list [string match "*cannot be opened for writing*write lock*" $r] [string match "*read-only*" $r]] {1 1}
set rd [mkitsql::db::openFile $f -readonly]
check "a reader is not kept out" [rows $rd] 10
mkitsql::db::closeFile $rd
set h [open $ready.go w] ; close $h
for {set i 0} {$i < 100 && [catch {exec kill -0 $holder}] == 0} {incr i} { after 50 }
check "the holder let go: a writer can open" [catch {mkitsql::db::closeFile [mkitsql::db::openFile $f]}] 0

# ---- a holder killed with SIGKILL leaves nothing behind ----
prepare ; file delete $ready $ready.go
set r [child die $f $ready]
check "the holder was killed" [lindex [lindex $r 2] 0] CHILDKILLED
set db [mkitsql::db::openFile $f]
mkitsql::db::appendRow $db.t k 55
check "after a kill: mkit-sql opens for writing and commits" [catch {mkitsql::db::commit $db}] 0
mkitsql::db::closeFile $db
check "... and the row is in" [rawRows] 11

# ---- another program committed first (it left the lock out) ----
prepare
set db [mkitsql::db::openFile $f]
mkitsql::run "INSERT INTO t VALUES (100)" $db
check "a program without the lock commits a row" [result [child raw-commit $f]] {RESULT COMMITTED}
set before [rawRows]
catch {mkitsql::run COMMIT $db} msg opts
check "COMMIT: {MKQL ERROR MKIT CHANGED}" [lrange [dict get $opts -errorcode] 0 3] {MKQL ERROR MKIT CHANGED}
check "... which says nothing was written and what to do" [list [string match "*nothing was written*" $msg] [string match "*ROLLBACK*" $msg]] {1 1}
check "nothing was written: the file still has the other program's 11 rows" [list [rawRows] $before] {11 11}
check "no commit record left" [file exists $f.commit] 0
check "the changes made here are still pending" [list [mkitsql::db::dirty $db] [rows $db]] {1 11}
mkitsql::run ROLLBACK $db
check "ROLLBACK loads the other program's row" [rows $db] 11
mkitsql::run "INSERT INTO t VALUES (101)" $db
check "repeating the change: COMMIT works" [catch {mkitsql::run COMMIT $db}] 0
check "... both programs' rows are in the file" [rawRows] 12
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f -verify]
check "the file opens again, verified" [rows $db] 12
check "the other program's row 777 is there" [lindex [dict get [mkitsql::run "SELECT COUNT(*) FROM t WHERE k = 777" $db] rows] 0 0] 1
mkitsql::db::closeFile $db

# ---- mkit-sql's own second handle on one file ----
prepare
set db [mkitsql::db::openFile $f]
check "the same path twice: refused by mkit-sql's own check" [string match "File is already open*" [catch {mkitsql::db::openFile $f} m ; set m]] 1
if {[catch {file link -hard $area/l.lnk $f}]} {
    puts "  (no hard links here: the second-name check is skipped)"
} else {
    set tags [mkitsql::db::tags]
    set rc [catch {mkitsql::db::openFile $area/l.lnk} m opts]
    check "a second name of the file (hard link): {MKIT LOCKED}" [list $rc [lrange [dict get $opts -errorcode] 0 2]] {1 {MKIT LOCKED 0}}
    check "... nothing registered, no lock file left for the second name" [list [mkitsql::db::tags] [file exists $area/l.lnk.lock]] [list $tags 0]
    mkitsql::db::appendRow $db.t k 55
    check "... and the first handle is untouched: it commits" [catch {mkitsql::db::commit $db}] 0
}
check "a read-only handle of mkit-sql beside the writer: refused by its own one-handle rule" [string match "File is already open*" [catch {mkitsql::db::openFile $f -readonly} m ; set m]] 1
check "a plain reader beside the writer sees the commit" [rawRows] [expr {[file exists $area/l.lnk] ? 11 : 10}]
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f]
check "after closing, the file opens for writing again" [expr {$db in [mkitsql::db::tags]}] 1
mkitsql::db::closeFile $db
file delete -force $area
puts "metakit lock: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
