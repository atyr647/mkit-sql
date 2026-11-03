# One contender in a race for the lock: waits for the go-file, tries to open the database for writing, reports WIN or LOCKED.
#   tclkit tests/lock_race_child.tcl <db> <result-file> <go-file>
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv db out go
set ::mkitsql::db::emptyStale 1 ; set ::mkitsql::db::mutexStale 1
while {![file exists $go]} { after 1 }
set rc [catch {mkitsql::db::takeLock $db} r opts]
set h [open $out w]
if {$rc} { puts $h "LOCKED $r" } elseif {$r eq ""} { puts $h "UNLOCKED" } else { puts $h WIN }
close $h
after 600
exit 0
