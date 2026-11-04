# The takeover of a stale lock, step by step and against starved and wrongly judging processes:   tclkit tests/lock_takeover.tcl
# (the same scenarios as MK Studio's tests/test_lock_crash.tcl, against mkit-sql's own lock code)
#   1. claimStale: the stale lock is MOVED ASIDE and the moved file judged; a live lock found there is put back unchanged.
#   2. a process held up between creating the lock file and writing it (taken for dead and overtaken) notices on waking.
#   3. a process holding the takeover guard, held up past a shortened guard limit, finds the lock it judged stale replaced by a live one.
#   4. a process held up right after moving the stale lock aside: a newcomer takes the free name, the woken one is refused.
#   5. two processes reap the same abandoned guard (a delete by name of the other one's fresh guard): both are inside the takeover,
#      and still never both own the database.
# Until this was written the takeover deleted the lock by name: in 3 and 5 the woken process destroyed a live owner's lock.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
if {$::tcl_platform(platform) eq "windows"} { puts "skipped on Windows (a file another process has open cannot be moved there)" ; exit 0 }
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <[string range $got 0 150]> want <$want>"} }
proc ok {n cond {detail ""}} { global pass fail ; if {$cond} {incr pass} else {incr fail ; puts "FAIL $n $detail"} }
set kit [info nameofexecutable] ; set host [info hostname]
set area [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_takeover_[pid]
file delete -force $area ; file mkdir $area
set db $area/to.mk
set ::mkitsql::db::emptyStale 1 ; set ::mkitsql::db::mutexStale 1 ; set ::mkitsql::db::takeStale 1     ;# (this process only: the children keep the real minute)
proc fresh {} { global db ; foreach f [glob -nocomplain $db*] { file delete $f } ; set h [open $db w] ; close $h }
proc rawlock {text} { global db ; set h [open $db.lock w] ; puts -nonewline $h $text ; close $h }
proc rawread {f} { set h [open $f r] ; set d [read $h] ; close $h ; return $d }
proc seenIn {log pat} { set s "" ; catch {set h [open $log r] ; set s [read $h] ; close $h} ; return [regexp $pat $s] }

# ---- 1. claimStale ---------------------------------------------------------------------------------------------------------------------
fresh
set lf [mkitsql::db::lockPath $db]
rawlock "999999 $host"
check "a dead owner's lock is looked at, judged stale, moved aside and deleted" [mkitsql::db::claimStale $lf] claimed
ok "... and the name is free, nothing left" [expr {![file exists $lf] && ![llength [mkitsql::db::takeovers $lf]]}]
check "nothing under the name" [mkitsql::db::claimStale $lf] gone
rawlock "4242 some-other-machine"                                ;# another host: always held - what a wrongly judged takeover would find
set before [list [file mtime $lf] [file size $lf]] ; file stat $lf st0
check "a live (foreign) lock found under the name is left alone" [mkitsql::db::claimStale $lf] alive
check "... with its text" [rawread $lf] "4242 some-other-machine"
check "... and its time and size" [list [file mtime $lf] [file size $lf]] $before
file stat $lf st1
ok "... and it is the very same file (it was never moved)" [expr {$st1(ino) == $st0(ino) && $st1(dev) == $st0(dev)}]
ok "... and no copy left" [expr {![llength [mkitsql::db::takeovers $lf]]}]
file delete $lf
set h [open $lf w] ; close $h                                    ;# an EMPTY lock that is brand new is not stale: the creator may be about to write
check "a brand-new empty lock is left alone" [mkitsql::db::claimStale $lf] alive
file delete $lf
file mkdir $lf                                                   ;# not a plain file: never taken, never ignored (no hard link of a folder: the move-first path)
check "a folder under the name is put back" [mkitsql::db::claimStale $lf] alive
ok "... still a folder" [file isdirectory $lf]
file delete $lf
# the lock is REPLACED while it is being judged: judged stale, then a live one under the name - it must not be taken
rawlock "999999 $host"
set ::replaced 0 ; set ::replLf $lf
set ::mkitsql::db::lockHook [list apply {{name} { if {$name eq "looked" && !$::replaced} { incr ::replaced ; file delete $::replLf ; set h [open $::replLf w] ; puts -nonewline $h "4242 some-other-machine" ; close $h } }}]
set r [mkitsql::db::claimStale $lf]
set ::mkitsql::db::lockHook ""
check "a lock replaced while it was judged is not taken" $r busy
check "... the live lock is still there" [rawread $lf] "4242 some-other-machine"
ok "... and no copy left" [expr {![llength [mkitsql::db::takeovers $lf]]}]
file delete $lf
set odd [file join $area "lock \[abc\] *?x.mk"]
set olf [mkitsql::db::lockPath $odd]
set h [open $olf w] ; puts -nonewline $h "4242 some-other-machine" ; close $h
check "odd file name: a live lock is put back" [mkitsql::db::claimStale $olf] alive
ok "... and the file is there" [file exists $olf]
set old [expr {[clock seconds] - 100}] ; set new [clock seconds]
foreach n [list $olf.take.$old.999999.1 $olf.take.$old.1.2 $olf.take.$new.999999.3] { set h [open $n w] ; close $h }
mkitsql::db::tidyTakeovers $olf
set rest {} ; foreach f [mkitsql::db::takeovers $olf] { lappend rest [file tail $f] }
check "tidy: only a file that is old AND whose process is gone goes (not an old one of a live process, not a recent one)" [lsort $rest] [lsort [list [file tail $olf].take.$old.1.2 [file tail $olf].take.$new.999999.3]]
foreach f [glob -nocomplain $area/*] { file delete -force $f }
file mkdir $area ; set h [open $db w] ; close $h
ok "stillMine: ours" [expr {[rawlock "1 a"] eq "" && [mkitsql::db::stillMine $lf "1 a"]}]
check "stillMine: somebody else's text" [mkitsql::db::stillMine $lf "2 b"] 0
file delete $lf
check "stillMine: gone" [mkitsql::db::stillMine $lf "1 a"] 0

# ---- stalled processes -----------------------------------------------------------------------------------------------------------------
proc overlapped {ev} {
    set iv {}
    dict for {pid d} $ev { if {[dict exists $d ACQUIRED]} { lappend iv [list [dict get $d ACQUIRED] [expr {[dict exists $d RELEASED] ? [dict get $d RELEASED] : [dict get $d ACQUIRED] + 1}]] } }
    if {[llength $iv] < 2} { return 0 }
    lassign [lindex $iv 0] a1 a2 ; lassign [lindex $iv 1] b1 b2
    return [expr {$a1 < $b2 && $b1 < $a2}]
}
proc setLimits {e m} { foreach {v x} [list MKIT_LOCK_EMPTY_STALE $e MKIT_LOCK_MUTEX_STALE $m] { set ::env($v) $x } }
proc parse {log} {
    set h [open $log r] ; set lines [split [string trim [read $h]] \n] ; close $h
    set ev {}
    foreach l $lines { lassign $l ms pid what ; dict set ev $pid $what $ms ; dict set ev $pid pid $pid }
    return [list $ev $lines]
}
# A stalls (up to 20 s) at STEP until released; B keeps trying for 6 s and holds 3 s; the parent releases A once B has decided.
proc stallRun {emptyStale step mutexStale} {
    global db kit here host area
    fresh
    if {$step in {checked looked claimed}} { rawlock "999999 $host" }
    set log $area/stall.log ; file delete $log $log.release
    setLimits $emptyStale $mutexStale
    set a [exec $kit $here/lock_stall_child.tcl $db 20000 800 $log $step 0 &]
    for {set i 0} {$i < 2400 && ![seenIn $log "\\m$a STALLED"]} {incr i} { after 50 }
    set b [exec $kit $here/lock_stall_child.tcl $db 0 3000 $log "" 6000 &]
    for {set i 0} {$i < 1800 && ![seenIn $log "\\m$b (ACQUIRED|REFUSED)"]} {incr i} { after 50 }
    close [open $log.release w]
    for {set i 0} {$i < 600 && ([mkitsql::pidAlive $a] || [mkitsql::pidAlive $b])} {incr i} { after 50 }
    lassign [parse $log] ev lines
    return [list $a $b $ev $lines]
}
# 2. starved between creating the lock file and writing it; the limit is 1 s, so B takes the file for abandoned
lassign [stallRun 1 created 1] a b ev lines
puts "  stall after creating the lock, limit 1 s: [join $lines {; }]"
ok "created-stall: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "created-stall: B overtook the starved A, and A, waking up, noticed and did not 'acquire'" [expr {[dict exists $ev $b ACQUIRED] && ![dict exists $ev $a ACQUIRED]}] $lines
# 3. held up inside the takeover past a (shortened) guard limit
lassign [stallRun 1 checked 1] a b ev lines
puts "  stall holding the guard, guard limit 1 s: [join $lines {; }]"
ok "guard-stall: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "guard-stall: B took over, the woken A found B's live lock, put it back and was refused" [expr {[dict exists $ev $b ACQUIRED] && ![dict exists $ev $a ACQUIRED] && [dict exists $ev $a REFUSED]}] $lines
ok "guard-stall: B's lock text survived A's attempt" [seenIn $area/stall.log "\\m$b VERIFY ok"] $lines
# 4. held up right after moving the stale lock aside
lassign [stallRun 60 claimed 60] a b ev lines
puts "  stall after moving the lock aside: [join $lines {; }]"
ok "aside-stall: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "aside-stall: the newcomer got the lock, the woken process was refused" [expr {[dict exists $ev $b ACQUIRED] && [dict exists $ev $a REFUSED]}] $lines
check "aside-stall: no litter" [lsort [glob -nocomplain $db.lock.take.*]] {}
# 4b. held up while looking at the stale lock (it has not been moved)
lassign [stallRun 60 looked 60] a b ev lines
puts "  stall while looking at the lock: [join $lines {; }]"
ok "look-stall: nobody held the lock at the same time as somebody else" [expr {![overlapped $ev]}] $lines
ok "look-stall: the woken process took the lock (nothing had changed)" [dict exists $ev $a ACQUIRED] $lines
check "look-stall: no litter" [lsort [glob -nocomplain $db.lock.take.*]] {}
# 5. two processes reap the same abandoned guard
proc reaperRace {} {
    global db kit here host area
    fresh
    set log $area/reap.log ; file delete $log $log.relA $log.relB
    setLimits 1 1
    rawlock "999999 $host"                                                       ;# the dead owner's lock
    close [open $db.lock.guard w] ; file mtime $db.lock.guard [expr {[clock seconds] - 100}]    ;# the guard a killed process left
    set a [exec $kit $here/lock_stall_child.tcl $db 30000 1500 $log guard-aged 9000 relA &]
    for {set i 0} {$i < 1200 && ![seenIn $log "\\m$a STALLED"]} {incr i} { after 50 }
    set b [exec $kit $here/lock_stall_child.tcl $db 30000 3500 $log checked 9000 relB &]
    for {set i 0} {$i < 1200 && ![seenIn $log "\\m$b STALLED"]} {incr i} { after 50 }
    close [open $log.relA w]                                  ;# A deletes B's fresh guard, takes over, holds the lock
    for {set i 0} {$i < 600 && ![seenIn $log "\\m$a ACQUIRED"]} {incr i} { after 50 }
    close [open $log.relB w]                                  ;# B carries on with its stale verdict
    for {set i 0} {$i < 1200 && !([seenIn $log "\\m$a RELEASED"] && [seenIn $log "\\m$b RELEASED"])} {incr i} { after 50 }
    lassign [parse $log] ev lines
    return [list $a $b $ev $lines]
}
lassign [reaperRace] a b ev lines
puts "  two reapers of one abandoned guard: [join $lines {; }]"
ok "reapers: both finished" [expr {[dict exists $ev $a RELEASED] && [dict exists $ev $b RELEASED]}] $lines
ok "reapers: never inside together" [expr {![overlapped $ev]}] $lines
ok "reapers: A kept its lock" [seenIn $area/reap.log "\\m$a VERIFY ok"] $lines
ok "reapers: B got the database after A was done" [expr {[dict exists $ev $b ACQUIRED] && [dict get $ev $b ACQUIRED] >= [dict get $ev $a RELEASED] && [seenIn $area/reap.log "\\m$b VERIFY ok"]}] $lines
check "reapers: nothing left behind" [lsort [glob -nocomplain $db.lock*]] {}

file delete -force $area
puts "lock takeover: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
