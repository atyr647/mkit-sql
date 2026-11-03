set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set db [mkitsql::db::openFile [lindex $argv 0] -readonly]
puts "[mkitsql::db::size $db.t] rows [dict get [mkitsql::run {SELECT COUNT(*) AS c FROM t} $db] rows]"
