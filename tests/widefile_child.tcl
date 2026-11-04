set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
set ::env(MKIT_WIDE) 0
source $here/mk4load.tcl
source $here/loadengine.tcl
if {[catch {mkitsql::db::openFile [lindex $argv 0]} m opts]} { puts "refused [lrange [dict get $opts -errorcode] 0 1]" } else { puts "opened" }
