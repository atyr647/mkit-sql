# Takes the write lock and is killed (SIGKILL) at one named step.   tclkit tests/lock_crash_child.tcl <db> <step> <done-file>
# steps: created (lock file exists, still empty) | written (lock complete) | mutex (holds the takeover guard)
#        | deleted (guard held, stale lock removed, new one not yet created) | released (after a normal close)
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv db step done
set ::mkitsql::db::emptyStale 1 ; set ::mkitsql::db::mutexStale 1
proc killself {} { catch {exec kill -9 [pid]} ; after 5000 }
set ::mkitsql::db::lockHook [list apply {{step name} { if {$name eq $step} { killself } }} $step]
catch {mkitsql::db::openFile $db} tag
if {$step eq "released"} { catch {mkitsql::db::closeFile $tag} }
set h [open $done w] ; puts $h "survived $tag" ; close $h
exit 0
