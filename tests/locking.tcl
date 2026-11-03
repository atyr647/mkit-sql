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
check lock_content_format [regexp {^(\d+) (\S+)$} [lockText] -> lpid lhost] 1
check lock_pid $lpid [pid]
check lock_host $lhost [info hostname]
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
check refusal_errorcode_has_role_endpoint [llength [dict get $opts -errorcode]] 6
check refusal_message [string match "This database is open for editing in another process (pid $cpid on *" $msg] 1
check refusal_left_lock_alone [lindex [split [lockText] " "] 0] $cpid
# read-only is allowed, notes the holder, and writes are refused with a message that names it
set rtag [mkitsql::db::openFile $f -readonly]
check readonly_notes_holder [lrange [mkitsql::db::lockedBy $rtag] 0 1] [list $cpid [info hostname]]
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
# a recycled pid: pid 1 is alive, but the lock file is older than that process (the lock was made by a previous owner of the pid)
if {[file exists /proc/1/stat]} {
    writeLock "1 [info hostname]"
    file mtime $f.lock 946684800                                    ;# the year 2000
    set tag [mkitsql::db::openFile $f] ; check recycled_pid_is_stale [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
    writeLock "1 [info hostname]"                                    ;# made just now: pid 1 really is the owner
    check live_pid_with_new_lock_respected [expr {[catch {mkitsql::db::openFile $f} m opts] ? [lindex [dict get $opts -errorcode] 2] : "opened"}] 1
    file delete $f.lock
}
# MK Studio writes only "pid host": still understood
writeLock ""
check empty_fresh_lock_respected [expr {[catch {mkitsql::db::openFile $f} m opts] ? "refused" : "opened"}] refused
file mtime $f.lock [expr {[clock seconds] - 60}]
set tag [mkitsql::db::openFile $f] ; check empty_old_lock_taken [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
# a takeover guard abandoned by a crash does not block (spec: older than 10 s)
writeLock "999999 [info hostname]"
set fh [open $f.lock.guard w] ; close $fh
file mtime $f.lock.guard [expr {[clock seconds] - 60}]
set tag [mkitsql::db::openFile $f] ; check old_guard_cleared [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
check guard_cleaned_up [file exists $f.lock.guard] 0
# the protocol's checks, written the way another implementation would: role and endpoint, foreign locks left untouched
writeLock "999 some-other-machine server tcp://db.example:5433"
set rc [catch {mkitsql::db::openFile $f} msg opts]
check spec_foreign_refused $rc 1
check spec_role_in_errorcode [lrange [dict get $opts -errorcode] 0 5] {MKIT LOCKED 999 some-other-machine server tcp://db.example:5433}
check spec_role_in_message [expr {[string first "server" $msg] >= 0 && [string first "tcp://db.example:5433" $msg] >= 0}] 1
set rtag [mkitsql::db::openFile $f -readonly]
check spec_readonly_allowed [expr {[mkitsql::db::lockedBy $rtag] ne ""}] 1
check spec_readonly_role [lrange [mkitsql::db::lockedBy $rtag] 2 3] {server tcp://db.example:5433}
mkitsql::db::closeFile $rtag
check spec_foreign_lock_untouched [lockText] "999 some-other-machine server tcp://db.example:5433"
writeLock "999999 [info hostname] server tcp://gone:1"
set tag [mkitsql::db::openFile $f] ; check spec_stale_with_role_taken [regexp "^[pid] [info hostname]\$" [lockText]] 1 ; mkitsql::db::closeFile $tag
writeLock "[pid] [info hostname]"
set tag [mkitsql::db::openFile $f] ; check spec_ours_taken_over [mkitsql::db::holdsLock $tag] 1 ; mkitsql::db::closeFile $tag
check spec_guard_left_nothing [glob -nocomplain $f.lock*] {}
# a server announces itself
set mkitsql::db::lockRole server ; set mkitsql::db::lockEndpoint tcp://here:1
set tag [mkitsql::db::openFile $f] ; check spec_server_announces [lockText] "[pid] [info hostname] server tcp://here:1" ; mkitsql::db::closeFile $tag
set mkitsql::db::lockRole "" ; set mkitsql::db::lockEndpoint ""
# a lock path that is not a regular file is refused, not followed (a link) and not read (a fifo would block)
file delete $f.lock
set target $area/lock_target.txt ; set fh [open $target w] ; puts $fh precious ; close $fh
exec ln -s $target $f.lock
check lock_symlink_refused [expr {[catch {mkitsql::db::openFile $f} m opts] ? [lrange [dict get $opts -errorcode] 0 1] : "opened"}] {MKIT BADLOCK}
check lock_symlink_target_untouched [expr {[file size $target] == 9}] 1
file delete $target
file delete $f.lock
if {![catch {exec mkfifo $f.lock}]} {
    set t0 [clock milliseconds]
    check lock_fifo_refused [expr {[catch {mkitsql::db::openFile $f} m opts] ? [lrange [dict get $opts -errorcode] 0 1] : "opened"}] {MKIT BADLOCK}
    check lock_fifo_did_not_block [expr {[clock milliseconds] - $t0 < 2000}] 1
    file delete $f.lock
}
# a huge lock file is read with a bound (only the first line matters)
set fh [open $f.lock w] ; puts -nonewline $fh "999 some-other-machine" ; puts -nonewline $fh [string repeat x 5000000] ; close $fh
set t0 [clock milliseconds]
check lock_huge_file_respected [expr {[catch {mkitsql::db::openFile $f} m opts] ? [list [lindex [dict get $opts -errorcode] 2] [expr {[string length [lindex [dict get $opts -errorcode] 3]] <= 512}]] : "opened"}] {999 1}
check lock_huge_file_read_fast [expr {[clock milliseconds] - $t0 < 3000}] 1
file delete $f.lock
# two names of one file share one lock (symbolic link), the lock sits at the real file
file delete -force $area/link.mk
exec ln -s $f $area/link.mk
set tag [mkitsql::db::openFile $area/link.mk]
check symlink_lock_at_real_file [list [file exists $f.lock] [file exists $area/link.mk.lock]] {1 0}
check symlink_second_name_refused [expr {[catch {mkitsql::db::openFile $f} m] ? [string match "*already open*" $m] : 0}] 1
mkitsql::db::closeFile $tag
file delete $area/link.mk
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
check race_leaves_no_guard [file exists $f.lock.guard] 0

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
