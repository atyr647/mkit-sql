# Child for tests/damage.tcl: open a file the verifier passed, read every plain column of every table, say OK or why not.
#   tclsh damage_read_child.tcl <dbfile>
# Metakit reads damaged data non-deterministically and can crash the process that does it: that process must not be the test.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
proc lmap_ {l script} { set out {} ; foreach c $l { lappend out [lindex $c 0] } ; return $out }
if {[catch {
    set tg [mkitsql::db::openFile [lindex $argv 0] -readonly -verify]
    foreach v [mkitsql::db::views $tg] { mkitsql::db::rows $tg.$v [lmap_ [lsearch -all -inline -not -index 1 -exact [mkitsql::db::layout $tg.$v] V] {c {lindex $c 0}}] 0 100000 }
    mkitsql::db::closeFile $tg
} msg]} { puts "ERR $msg" ; exit 1 }
puts OK
