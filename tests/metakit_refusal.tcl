# A Metakit that refuses to write (its own OS-level write lock, its check that the file changed under us) must reach the caller as a clear
# SQL-level error: never swallowed, never folded into "full disk", never rolled back over the other writer's data.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/metakit_refusal.tcl
# The Metakit fork that has the lock is not part of this repository yet, so the refusal is SIMULATED: `mk::file open` / `mk::file commit`
# are wrapped and raise what such a Metakit would (with an -errorcode, and with only words in the message).  This proves what mkit-sql
# does with a refusal; it does not prove what the real fork says - see `refusalWords` in db.tcl.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/mkutil.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 300]\n  want: [string range $want 0 300]"} }
set area [tmp mkitsql_refuse_[pid]] ; file delete -force $area ; file mkdir $area
set f $area/r.mk
proc clean {} { foreach x [glob -nocomplain $::f $::f.*] { file delete -force $x } }
proc bytes {p} { set h [open $p rb] ; set d [read $h] ; close $h ; return $d }
proc prepare {} {
    clean
    set db [mkitsql::db::openFile $::f -create]
    mkitsql::db::createView $db t {{k I {}}}
    for {set i 0} {$i < 10} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    return $db
}
# the simulated Metakit: refuse `mk::file <what>` with this error while ::refuse is set
rename ::mk::file ::mk::fileReal
set ::refuse "" ; set ::opens 0
proc ::mk::file {sub args} {
    if {$sub eq "open"} { incr ::opens }
    if {$sub eq $::refuse} { return -options $::refuseOpts $::refuseMsg }
    uplevel 1 [list ::mk::fileReal $sub {*}$args]
}
proc refuseWith {what msg {code NONE}} { set ::refuse $what ; set ::refuseMsg $msg ; set ::refuseOpts [list -code error -errorcode $code] }
proc sql {text db} { if {![catch {mkitsql::run $text $db} msg opts]} { return {NONE {}} } ; return [list [dict get $opts -errorcode] $msg] }
proc rows {db} { return [lindex [dict get [mkitsql::run "SELECT COUNT(*) FROM t" $db] rows] 0 0] }

# ---- commit refused: stale write, by -errorcode ----
set db [prepare]
mkitsql::run "INSERT INTO t VALUES (100)" $db
set before [bytes $f]
refuseWith commit "the file was modified" {METAKIT STALE}
lassign [sql COMMIT $db] code msg
check "stale (errorcode): an engine error with the storage class" [lrange $code 0 3] {MKQL ERROR MKIT STALEWRITE}
check "stale: the message says what happened and what to do" [list [string match "*changed by another program*" $msg] [string match "*ROLLBACK*" $msg]] {1 1}
check "stale: the message is not the full-disk one" [string match "*full disk*" $msg] 0
check "stale: the file is byte for byte as it was" [bytes $f] $before
check "stale: no commit record is left to undo anybody's data" [file exists $f.commit] 0
check "stale: the changes are still pending, not rolled back" [list [mkitsql::db::dirty $db] [rows $db]] {1 11}
check "stale: the handle is still open" [expr {$db in [mkitsql::db::tags]}] 1
set ::refuse ""
check "after the refusal is gone the same COMMIT works" [sql COMMIT $db] {NONE {}}
check "... and the rows are in the file" [rows $db] 11
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f -readonly] ; check "... for a new reader too" [rows $db] 11 ; mkitsql::db::closeFile $db

# ---- commit refused: the lock, by words only (no -errorcode) ----
foreach msg {"file is locked by another process" "could not lock the database" "database already open for writing"} {
    set db [prepare] ; mkitsql::run "INSERT INTO t VALUES (100)" $db
    refuseWith commit $msg
    lassign [sql COMMIT $db] code text
    check "lock ($msg): code" $code {MKQL ERROR MKIT LOCKED 0 unknown {} {}}
    check "lock ($msg): says whose lock and that nothing was written" [list [string match "*Metakit's write lock*" $text] [string match "*Nothing was written*" $text]] {1 1}
    check "lock ($msg): record gone, changes pending" [list [file exists $f.commit] [mkitsql::db::dirty $db]] {0 1}
    set ::refuse ""
    mkitsql::db::rollback $db ; check "lock ($msg): ROLLBACK discards the pending change" [rows $db] 10
    mkitsql::db::closeFile $db
}
# the same through the errorcode the fork may use
set db [prepare] ; mkitsql::run "INSERT INTO t VALUES (100)" $db
refuseWith commit "refused" {MK4TCL LOCKED}
check "lock (errorcode MK4TCL LOCKED)" [lindex [sql COMMIT $db] 0] {MKQL ERROR MKIT LOCKED 0 unknown {} {}}
set ::refuse "" ; mkitsql::db::closeFile $db

# ---- autocommit: the write statement itself reports it ----
set db [prepare]
set mkitsql::autocommit 1
refuseWith commit "file is locked" {}
lassign [sql "INSERT INTO t VALUES (101)" $db] code msg
check "autocommit: the INSERT reports the refusal" [lrange $code 0 3] {MKQL ERROR MKIT LOCKED}
set mkitsql::autocommit 0 ; set ::refuse "" ; mkitsql::db::closeFile $db

# ---- open refused ----
prepare ; mkitsql::db::closeFile [lindex [mkitsql::db::tags] 0]
set tagsBefore [mkitsql::db::tags]
refuseWith open "cannot lock the file" {METAKIT LOCKED}
set ::opens 0
set rc [catch {mkitsql::db::openFile $f} msg opts]
check "open refused: an error with the lock class" [list $rc [lrange [dict get $opts -errorcode] 0 2]] {1 {MKIT LOCKED 0}}
check "open refused: the message says so" [string match "*cannot be opened for writing*Metakit's write lock*" $msg] 1
check "open refused: asked once, not retried in another way" $::opens 1
check "open refused: our own lock file was given back" [file exists $f.lock] 0
check "open refused: nothing registered" [mkitsql::db::tags] $tagsBefore
check "open refused: the file is untouched and no record" [file exists $f.commit] 0
set ::refuse ""
set db [mkitsql::db::openFile $f] ; check "open works once the refusal is gone" [rows $db] 10 ; mkitsql::db::closeFile $db

# ---- an ordinary commit failure is still handled as one (restored, reopened, MKIT COMMITFAILED) ----
set db [prepare] ; mkitsql::run "INSERT INTO t VALUES (100)" $db
refuseWith commit "I/O error during commit"
lassign [sql COMMIT $db] code msg
check "ordinary failure: still COMMITFAILED" [lrange $code 0 3] {MKQL ERROR MKIT COMMITFAILED}
check "ordinary failure: the database is back at its last commit" [rows $db] 10
set ::refuse "" ; mkitsql::db::closeFile $db

# ---- a refusal never needs a Metakit that has the lock: the normal path is unchanged ----
set ::refuse ""
set db [prepare] ; mkitsql::run "INSERT INTO t VALUES (100)" $db
check "no refusal: COMMIT works" [sql COMMIT $db] {NONE {}}
mkitsql::db::closeFile $db
rename ::mk::file {} ; rename ::mk::fileReal ::mk::file
file delete -force $area
puts "metakit refusal: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
