# Advisory write lock (<file>.lock, the same protocol MK Studio uses) and sessions.  Real processes race for
# the same file, die while holding it, and reuse pids.
#   tclsh tests/locking.tcl            (MKSTUDIO_DIR=/path/to/mkstudio also checks interoperability with its store.tcl)
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
if {$::tcl_platform(platform) eq "windows"} { puts "skipped on Windows" ; exit 0 }
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set area $tmp/mkitsql_lock_[pid]
file delete -force $area ; file mkdir $area
set f $area/db.mk
set me [info nameofexecutable]
proc child {file hold {ro ""}} {
    set ch [open |[list $::me $::here/locking_child.tcl $file $hold $ro] r+]
    fconfigure $ch -buffering line
    return $ch
}
proc firstLine {ch} { while {[gets $ch line] >= 0} { if {![string match "(*" $line]} { return $line } } ; return "" }
proc release {ch} { catch {puts $ch go ; flush $ch} }
proc lockText {} { set h [open $::f.lock] ; set d [read $h] ; close $h ; return $d }

# ---- one process --------------------------------------------------------------------------------------------------
set tag [mkitsql::db::openFile $f -create]
check lock_file_made [file exists $f.lock] 1
lassign [split [lockText] " "] lpid lhost lstart
check lock_pid $lpid [pid]
check lock_host $lhost [info hostname]
check lock_start_token [expr {$lstart eq "" || [string is integer -strict $lstart]}] 1
check holds_lock [mkitsql::db::holdsLock $tag] 1
check second_open_same_process [expr {[catch {mkitsql::db::openFile $f} m] && [string match "*already open*" $m]}] 1
mkitsql::db::closeFile $tag
check lock_removed_on_close [file exists $f.lock] 0

# closing never deletes a lock that is no longer ours
set tag [mkitsql::db::openFile $f]
set fh [open $f.lock w] ; puts -nonewline $fh "4242 otherhost" ; close $fh
mkitsql::db::closeFile $tag
check foreign_lock_survives_close [file exists $f.lock] 1
file delete $f.lock

# ---- a live writer in another process ---------------------------------------------------------------------------------
set c [child $f stdin]
set l [firstLine $c]
check child_won [string match "WON *" $l] 1
set cpid [lindex $l 1]
check lock_names_child [lindex [split [lockText] " "] 0] $cpid
set rc [catch {mkitsql::db::openFile $f} msg opts]
check live_holder_refuses [list $rc [lrange [dict get $opts -errorcode] 0 3]] [list 1 [list MKIT LOCKED $cpid [info hostname]]]
check refusal_message [string match "This database is open for editing in another process (pid $cpid on *" $msg] 1
check refusal_left_lock_alone [lindex [split [lockText] " "] 0] $cpid
# read-only is allowed, notes the holder, and writes are refused with a message that names it
set rtag [mkitsql::db::openFile $f -readonly]
check readonly_notes_holder [mkitsql::db::lockedBy $rtag] [list $cpid [info hostname]]
check readonly_takes_no_lock [mkitsql::db::holdsLock $rtag] 0
set m [expr {[catch {mkitsql::run "CREATE TABLE z (a INT)" $rtag} m] ? $m : "no error"}]
check write_refused_names_holder [string match "*open read-only: process $cpid on * has it open for editing*" $m] 1
mkitsql::db::closeFile $rtag
check readonly_close_keeps_their_lock [file exists $f.lock] 1
release $c
check child_closed [firstLine $c] CLOSED
catch {close $c}
check lock_gone_after_holder_closed [file exists $f.lock] 0

# ---- a holder that dies without cleaning up (kill -9) is taken over ---------------------------------------------------------
set c [child $f stdin]
set l [firstLine $c] ; set cpid [lindex $l 1]
exec kill -9 $cpid
catch {close $c}
check stale_lock_left_behind [file exists $f.lock] 1
check dead_process_is_dead [mkitsql::pidAlive $cpid] 0
set tag [mkitsql::db::openFile $f]
check stale_lock_taken_over [lindex [split [lockText] " "] 0] [pid]
mkitsql::db::closeFile $tag

# ---- lock files written by something else -----------------------------------------------------------------------------------------
proc writeLock {text} { set fh [open $::f.lock w] ; puts -nonewline $fh $text ; close $fh }
writeLock "999999 [info hostname]"
set tag [mkitsql::db::openFile $f] ; check dead_pid_lock_taken [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
writeLock "1 otherhost"
check other_host_respected [expr {[catch {mkitsql::db::openFile $f} m opts] ? [lrange [dict get $opts -errorcode] 0 3] : "opened"}] {MKIT LOCKED 1 otherhost}
file delete $f.lock
# a recycled pid: pid 1 is alive, but this lock says it started at some other time
if {[file exists /proc/1/stat]} {
    writeLock "1 [info hostname] 1"
    set tag [mkitsql::db::openFile $f] ; check recycled_pid_is_stale [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
    writeLock "1 [info hostname] [mkitsql::db::procStart 1]"
    check same_start_token_is_live [expr {[catch {mkitsql::db::openFile $f} m opts] ? [lindex [dict get $opts -errorcode] 2] : "opened"}] 1
    file delete $f.lock
}
# MK Studio writes only "pid host": still understood
writeLock "[pid]x [info hostname]"
writeLock ""
check empty_fresh_lock_respected [expr {[catch {mkitsql::db::openFile $f} m opts] ? "refused" : "opened"}] refused
file mtime $f.lock [expr {[clock seconds] - 60}]
set tag [mkitsql::db::openFile $f] ; check empty_old_lock_taken [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
# a crashed takeover leaves its mutex behind
writeLock "999999 [info hostname]"
set fh [open $f.lock.takeover w] ; close $fh
file mtime $f.lock.takeover [expr {[clock seconds] - 120}]
set tag [mkitsql::db::openFile $f] ; check old_takeover_mutex_cleared [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
check no_files_left [lsort [glob -nocomplain -directory $area *]] [list $f]

# ---- races: N processes open the same file at the same moment; exactly one wins -----------------------------------------------------
proc race {n staleFirst} {
    if {$staleFirst} { writeLock "999999 [info hostname]" } else { file delete $::f.lock }
    set cs {}
    for {set i 0} {$i < $n} {incr i} { lappend cs [child $::f stdin] }
    set won 0 ; set locked 0 ; set other {}
    foreach c $cs {
        set l [firstLine $c]
        switch -glob -- $l { "WON *" {incr won} "LOCKED *" {incr locked} default {lappend other $l} }
    }
    foreach c $cs { release $c }
    foreach c $cs { catch {gets $c} }
    foreach c $cs { catch {close $c} }
    return [list $won $locked $other]
}
set bad 0
for {set round 0} {$round < 12} {incr round} {
    lassign [race 6 [expr {$round % 2}]] won locked other
    if {$won != 1 || $locked != 5 || [llength $other]} { incr bad ; puts "round $round: won $won locked $locked other $other" }
}
check race_exactly_one_winner $bad 0
check race_leaves_no_lock [file exists $f.lock] 0
check race_leaves_no_mutex [file exists $f.lock.takeover] 0

# ---- readers do not need (or take) the lock; many may read while one writes ---------------------------------------------------------------
set w [child $f stdin] ; firstLine $w
set r1 [child $f 0.2 readonly] ; set r2 [child $f 0.2 readonly]
check readers_ok [list [string match "WON *" [firstLine $r1]] [string match "WON *" [firstLine $r2]]] {1 1}
release $w ; firstLine $w ; catch {close $w}
catch {firstLine $r1} ; catch {firstLine $r2} ; catch {close $r1} ; catch {close $r2}

# ---- interoperability with MK Studio's own store.tcl (separate processes on both sides) ------------------------------------------------------
if {[info exists ::env(MKSTUDIO_DIR)] && [file exists $::env(MKSTUDIO_DIR)/mkstudio.vfs/lib/app-mkstudio/store.tcl]} {
    set storeTcl $::env(MKSTUDIO_DIR)/mkstudio.vfs/lib/app-mkstudio/store.tcl
    # MK Studio holds the file; we must refuse to write, and may read
    set sc [open |[list $me $here/locking_child_studio.tcl $storeTcl $f] r+] ; fconfigure $sc -buffering line
    set l [firstLine $sc]
    if {[string match "WON *" $l]} {
        check studio_holds_lock_file [file exists $f.lock] 1
        check we_respect_studios_lock [expr {[catch {mkitsql::db::openFile $f} m opts] ? [lrange [dict get $opts -errorcode] 0 1] : "opened"}] {MKIT LOCKED}
        set rtag [mkitsql::db::openFile $f -readonly]
        check we_read_while_studio_writes [lindex [mkitsql::db::lockedBy $rtag] 0] [lindex $l 1]
        mkitsql::db::closeFile $rtag
        release $sc ; firstLine $sc ; catch {close $sc}
        check studio_released [file exists $f.lock] 0
    } else { check studio_child_started $l WON ; catch {close $sc} }
    # we hold the file; MK Studio must refuse
    set c [child $f stdin] ; firstLine $c
    set sc [open |[list $me $here/locking_child_studio.tcl $storeTcl $f] r+] ; fconfigure $sc -buffering line
    check studio_respects_our_lock [string match "LOCKED STORE LOCKED *" [firstLine $sc]] 1
    catch {close $sc}
    release $c ; firstLine $c ; catch {close $c}
    # and a stale lock left by a killed MK Studio is taken over by us
    set sc [open |[list $me $here/locking_child_studio.tcl $storeTcl $f] r+] ; fconfigure $sc -buffering line
    set l [firstLine $sc] ; exec kill -9 [lindex $l 1] ; catch {close $sc}
    set tag [mkitsql::db::openFile $f] ; check we_take_over_killed_studios_lock [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
} else { puts "(set MKSTUDIO_DIR to check interoperability with MK Studio's store.tcl)" }

# ---- sessions: whose transaction is it? ---------------------------------------------------------------------------------------------------
set tag [mkitsql::db::openFile $f]
proc q {sql} { mkitsql::run $sql $::tag }
proc err {sql} { if {[catch {q $sql} m]} { return $m } ; return ok }
q "CREATE TABLE s (id INT, v TEXT)" ; q "COMMIT"
check no_session_no_ownership [err "INSERT INTO s VALUES (1, 'x')"] ok
q "ROLLBACK"
set mkitsql::session alice
check alice_writes [err "INSERT INTO s VALUES (1, 'a')"] ok
set mkitsql::session bob
check bob_blocked_insert [string match "*uncommitted changes from another session (alice)*" [err "INSERT INTO s VALUES (2, 'b')"]] 1
check bob_blocked_update [string match "*another session*" [err "UPDATE s SET v = 'z'"]] 1
check bob_blocked_delete [string match "*another session*" [err "DELETE FROM s"]] 1
check bob_blocked_ddl [string match "*another session*" [err "DROP TABLE s"]] 1
check bob_blocked_commit [string match "*only that session can commit*" [err "COMMIT $tag"]] 1
check bob_blocked_rollback [string match "*only that session can rollback*" [err "ROLLBACK $tag"]] 1
check bob_can_read [dict get [q "SELECT COUNT(*) FROM s"] rows] 1
check bob_nothing_to_commit [string match "Nothing to commit*" [dict get [q "COMMIT"] text]] 1
set mkitsql::session alice
check alice_continues [err "INSERT INTO s VALUES (3, 'c')"] ok
q "COMMIT"
set mkitsql::session bob
check bob_writes_after_commit [err "INSERT INTO s VALUES (4, 'd')"] ok
set mkitsql::session alice
check alice_blocked_now [string match "*another session (bob)*" [err "UPDATE s SET v = 'q'"]] 1
set mkitsql::session bob
q "ROLLBACK"
set mkitsql::session alice
check alice_free_after_rollback [err "UPDATE s SET v = 'q'"] ok
q "ROLLBACK"
set mkitsql::session ""
check count_after [dict get [q "SELECT COUNT(*) FROM s"] rows] 2
mkitsql::db::closeFile $tag

file delete -force $area
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
