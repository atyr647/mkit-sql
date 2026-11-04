# Takes the write lock, but is "descheduled" at one point of the acquisition (what a starved process on an overloaded machine looks
# like): it waits there until the parent creates <log>.<release-name>, then carries on and holds the lock.  (The same child as MK Studio's
# tests/lock_stall_child.tcl, against mkit-sql's own lock code.)
#   tclkit tests/lock_stall_child.tcl <db> <stall-max-ms> <hold-ms> <log-file> ?<step>? ?<retry-ms>? ?<release-name>?
#   step: created (default) = the lock file exists but is still empty | checked = holding the takeover guard, the lock has been
#         judged stale, nothing changed yet | guard-aged = the guard was judged abandoned and is about to be deleted |
#         claimed = the stale lock has been moved aside, not yet judged.      stall-max-ms 0 = no stall.
#   retry-ms: keep trying to get the lock for this long (a process that finds it held tries again); then give up (REFUSED)
#   MKIT_LOCK_EMPTY_STALE / MKIT_LOCK_MUTEX_STALE (seconds) shorten the abandonment limits
# Log lines:  <ms-since-epoch> <pid> STALLED | ACQUIRED | REFUSED | VERIFY ok|lost | RELEASED
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv db stall hold log step retry rel
if {$step eq ""} { set step created }
if {$rel eq ""} { set rel release }
if {$retry eq ""} { set retry 0 }
if {[info exists ::env(MKIT_LOCK_EMPTY_STALE)]} { set ::mkitsql::db::emptyStale $::env(MKIT_LOCK_EMPTY_STALE) }
if {[info exists ::env(MKIT_LOCK_MUTEX_STALE)]} { set ::mkitsql::db::mutexStale $::env(MKIT_LOCK_MUTEX_STALE) }
proc logline {t} { global log ; set h [open $log a] ; puts $h "[clock milliseconds] [pid] $t" ; close $h }
set ::mkitsql::db::lockHook [list apply {{step stall log rel name} {
    if {$name eq $step && $stall > 0} {
        uplevel #0 {logline STALLED}                  ;# tells the parent that this process is now stuck at the chosen point
        for {set i 0} {$i < $stall / 20 && ![file exists $log.$rel]} {incr i} { after 20 }
    }
}} $step $stall $log $rel]
set t0 [clock milliseconds]
while 1 {
    if {![catch {mkitsql::db::takeLock $db} mine] && $mine ne ""} break
    if {[clock milliseconds] - $t0 >= $retry} { logline REFUSED ; exit 0 }
    after 100
}
logline ACQUIRED
after $hold
logline "VERIFY [expr {[mkitsql::db::stillMine [mkitsql::db::lockPath $db] $mine] ? {ok} : {lost}}]"
logline RELEASED
mkitsql::db::releaseLock $db $mine
exit 0
