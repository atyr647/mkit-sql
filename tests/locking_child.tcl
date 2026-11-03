# Child process for tests/locking.tcl:  tclsh locking_child.tcl <dbfile> <hold: seconds or "stdin"> [readonly]
# Tries to open the file; prints WON or LOCKED <pid> <host> or ERROR <msg>; if it won, holds the file until the parent
# writes a line (or closes the pipe), then closes it properly.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv f hold ro
fconfigure stdout -buffering line
if {[catch {mkitsql::db::openFile $f {*}[expr {$ro eq "readonly" ? {-readonly} : {-create}}]} tag opts]} {
    set ec [dict get $opts -errorcode]
    if {[lrange $ec 0 1] eq {MKIT LOCKED}} { puts "LOCKED [lindex $ec 2] [lindex $ec 3]" } else { puts "ERROR $tag" }
    exit 0
}
puts "WON [pid] [mkitsql::db::lockedBy $tag]"
if {$hold eq "stdin"} { gets stdin } else { after [expr {int($hold * 1000)}] }
mkitsql::db::closeFile $tag
puts "CLOSED"
