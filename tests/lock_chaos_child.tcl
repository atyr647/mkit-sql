# Takes the write lock over and over, checking that nobody else is inside at the same time.
#   tclkit tests/lock_chaos_child.tcl <db> <log-file> <stop-file>
# Inside = holding the lock: the process writes its pid to <db>.inside and checks on the way out that it is still its own.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv db log stop
set ::mkitsql::db::emptyStale 1 ; set ::mkitsql::db::mutexStale 1
proc logline {text} { global log ; set h [open $log a] ; fconfigure $h -translation lf ; puts $h $text ; close $h }
expr {srand([pid])}
while {![file exists $stop]} {
    if {[catch {mkitsql::db::openFile $db} tag]} { after [expr {1 + int(rand() * 8)}] ; continue }
    set marker $db.inside
    set h [open $marker w] ; puts -nonewline $h [pid] ; close $h
    logline "WIN [pid]"
    after [expr {2 + int(rand() * 25)}]
    set seen ""
    catch {set h [open $marker r] ; set seen [string trim [read $h]] ; close $h}
    if {$seen ne [pid]} { logline "VIOLATION [pid] found $seen inside with it" }
    file delete $marker
    mkitsql::db::closeFile $tag
}
exit 0
