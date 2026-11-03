# The FIRST commit of a brand-new database through mkit-sql's storage layer; killed part-way by tests/first_commit.tcl (strace).
#   tclkit tests/first_commit_child.tcl <db>
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set t [mkitsql::db::openFile [lindex $argv 0] -create]
mkitsql::db::createView $t items {{id I {}} {label S {}}}
for {set i 0} {$i < 300} {incr i} { mkitsql::db::appendRow $t.items {id label} [list $i "row number $i with some text to fill pages"] }
mkitsql::db::commit $t
mkitsql::db::closeFile $t
