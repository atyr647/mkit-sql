# The write lock under CRASHES (the same scenarios as MK Studio's tests/test_lock_crash.tcl, run against mkit-sql's own lock code):
#   A. a process is killed at every step of acquiring, taking over and releasing the lock; afterwards another process must
#      still be able to take the database, in bounded time, leaving no litter behind.
#   B. a deterministic regression for the race both implementations had: a competitor deletes the stale lock between our failed
#      create and our look at it - we must retry, never conclude "this folder cannot hold a lock" and run unlocked.
#   C. chaos: eight processes take the lock in a loop while the test keeps killing random ones; no two ever inside at once.
#   D. races: N processes take the same stale lock at once; exactly one wins every round (LOCK_ROUNDS, default 40).
#   tclkit tests/lock_crash.tcl          (LOCK_CHAOS_SECONDS, default 6; 0 skips C)
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
if {$::tcl_platform(platform) eq "windows"} { puts "skipped on Windows" ; exit 0 }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 150]> want <$want>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
set kit [info nameofexecutable] ; set host [info hostname]
set area [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_lockcrash_[pid]
file delete -force $area ; file mkdir $area
set db $area/lc.mk
set ::mkitsql::db::emptyStale 1 ; set ::mkitsql::db::mutexStale 1          ;# abandonment timers shortened, here and in every child
proc fresh {} { global db ; foreach f [glob -nocomplain $db*] { file delete $f } ; set h [open $db w] ; close $h }
proc rawlock {text} { global db ; set h [open $db.lock w] ; puts -nonewline $h $text ; close $h }
proc rawread {} { global db ; set h [open $db.lock r] ; set d [read $h] ; close $h ; return $d }
proc take {} { global db ; if {[catch {mkitsql::db::takeLock $db} r]} { return "" } ; return $r }

# ---- A. killed at each step -----------------------------------------------------------------------------------------------
proc crashAt {step preseed} {
    global db kit here host area
    fresh
    if {$preseed} { rawlock "999999 $host" }
    set done $area/done ; file delete $done
    set pid [exec $kit $here/lock_crash_child.tcl $db $step $done &]
    for {set i 0} {$i < 400 && [mkitsql::pidAlive $pid]} {incr i} { after 25 }
    return [list $pid [file exists $done]]
}
proc acquireWithin {seconds} {
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < $seconds * 1000} {
        set r [take]
        if {$r ne ""} { return [list $r [expr {[clock milliseconds] - $t0}]] }
        after 40
    }
    return [list "" -1]
}
foreach {name step preseed expectFiles} {
    killed_after_creating_the_lock     created 0 {lock}
    killed_after_writing_the_lock      written 0 {lock}
    killed_holding_the_takeover_guard  mutex   1 {lock mutex}
    killed_between_delete_and_create   deleted 1 {mutex}
    killed_after_a_normal_release      released 0 {}
} {
    lassign [crashAt $step $preseed] pid survived
    check "$name: the process really died at the step" $survived 0
    set have {}
    if {[file exists $db.lock]} { lappend have lock }
    if {[file exists $db.lock.guard]} { lappend have mutex }
    check "$name: what it left behind" $have $expectFiles
    lassign [acquireWithin 8] mine ms
    ok "$name: another process can still take the database (took $ms ms)" [expr {$mine ne "" && $ms < 6000}] "no lock within 8 s; files: [glob -nocomplain $db.*]"
    if {$mine ne ""} {
        ok "$name: the new owner is recorded" [string match "[pid] *" [rawread]]
        mkitsql::db::releaseLock $db $mine
        set left [lsort [glob -nocomplain $db.lock*]]
        if {$left eq "$db.lock.guard"} {
            after 2200                       ;# an abandoned guard is harmless: it ages out
            set m2 [lindex [acquireWithin 8] 0]
            ok "$name: a leftover guard does not block the next owner" [expr {$m2 ne ""}]
            if {$m2 ne ""} { mkitsql::db::releaseLock $db $m2 }
            set left [lsort [glob -nocomplain $db.lock*]]
        }
        check "$name: nothing left after a release" $left {}
    }
}

# ---- B. the vanished-lock race, deterministically ---------------------------------------------------------------------------------
fresh
rawlock "999999 $host"                                                 ;# a stale lock
set ::hits 0
set ::mkitsql::db::lockHook [list apply {{name} { if {$name eq "create-failed" && !$::hits} { incr ::hits ; file delete $::db.lock } }}]
set r [take]
set ::mkitsql::db::lockHook ""
check "vanished lock: the hook fired" $::hits 1
ok "vanished lock: we retried and own the lock (not 'unlocked')" [expr {$r ne ""}] "takeLock returned [list $r]"
ok "vanished lock: the lock file names us" [expr {[file exists $db.lock] && [string match "[pid] *" [rawread]]}]
if {$r ne ""} { mkitsql::db::releaseLock $db $r }
# a folder that refuses files really does mean "run unlocked"
set ro $area/ro ; file mkdir $ro ; set rodb $ro/x.mk ; set h [open $rodb w] ; close $h ; file attributes $ro -permissions u=rx,go=
if {[file writable $ro]} { puts "  (running as root: read-only folder check skipped)" } else {
    check "read-only folder: runs unlocked" [mkitsql::db::takeLock $rodb] ""
}
file attributes $ro -permissions u=rwx,go=

# ---- D. races for a stale lock --------------------------------------------------------------------------------------------------------
set rounds [expr {[info exists ::env(LOCK_ROUNDS)] ? $::env(LOCK_ROUNDS) : 40}]
set badRounds 0
for {set round 0} {$round < $rounds} {incr round} {
    fresh ; rawlock "999999 $host"
    set go $area/go ; file delete $go
    set cs {} ; set outs {}
    for {set i 0} {$i < 6} {incr i} {
        set out $area/race$i ; file delete $out ; lappend outs $out
        lappend cs [exec $kit $here/lock_race_child.tcl $db $out $go &]
    }
    after 150 ; close [open $go w]
    for {set w 0} {$w < 200} {incr w} { set done 0 ; foreach o $outs { if {[file exists $o] && [file size $o] > 0} { incr done } } ; if {$done == 6} break ; after 25 }
    set wins 0 ; set other {}
    foreach o $outs { if {[file exists $o]} { set h [open $o] ; set l [string trim [read $h]] ; close $h ; if {[string match WIN* $l]} { incr wins } elseif {![string match LOCKED* $l]} { lappend other $l } } else { lappend other missing } }
    if {$wins != 1 || [llength $other]} { incr badRounds ; puts "  round $round: $wins winners, other: $other" }
    foreach c $cs { catch {exec kill -9 $c} }
    foreach o $outs { file delete $o }
}
check "$rounds races for a stale lock: exactly one winner every time" $badRounds 0

# ---- C. chaos --------------------------------------------------------------------------------------------------------------------------------
set secs [expr {[info exists ::env(LOCK_CHAOS_SECONDS)] ? $::env(LOCK_CHAOS_SECONDS) : 6}]
if {$secs <= 0} { puts "  (chaos part skipped)" } else {
    fresh
    set log $area/chaos.log ; set stop $area/chaos.stop
    file delete $log $stop $db.inside
    proc spawn {} { global kit here db log stop ; return [exec $kit $here/lock_chaos_child.tcl $db $log $stop &] }
    set pids {} ; for {set k 0} {$k < 8} {incr k} { lappend pids [spawn] }
    set end [expr {[clock milliseconds] + $secs * 1000}] ; set kills 0
    expr {srand(7)}
    while {[clock milliseconds] < $end} {
        after 120
        set i [expr {int(rand() * [llength $pids])}]
        catch {exec kill -9 [lindex $pids $i]} ; incr kills
        set pids [lreplace $pids $i $i [spawn]]
    }
    close [open $stop w] ; after 1500
    foreach p $pids { catch {exec kill -9 $p} }
    after 300
    set h [open $log r] ; set lines [split [string trim [read $h]] \n] ; close $h
    set wins 0 ; set viol {} ; set winners {}
    foreach l $lines { if {[string match "WIN *" $l]} { incr wins ; dict set winners [lindex $l 1] 1 } elseif {[string match "VIOLATION*" $l]} { lappend viol $l } }
    puts "  chaos: $kills processes killed, $wins acquisitions by [dict size $winners] different processes, [llength $viol] violations"
    check "chaos: never two live processes holding the lock" $viol {}
    ok "chaos: the lock kept being acquired (no deadlock)" [expr {$wins >= 15}] "only $wins acquisitions"
    ok "chaos: acquired by several different processes" [expr {[dict size $winners] >= 3}] "only [dict size $winners]"
    lassign [acquireWithin 8] m3 ms
    ok "chaos: still available afterwards (took $ms ms)" [expr {$m3 ne ""}]
    if {$m3 ne ""} { mkitsql::db::releaseLock $db $m3 }
}
file delete -force $area
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
