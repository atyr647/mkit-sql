# Adapted from MK Studio's tests/test_power_loss.tcl (same scenarios and models), run against mkit-sql's OWN storage layer
# (tests/power_shim.tcl forwards the store:: calls).
# power_commit_child.tcl -- one real commit through mkit-sql's storage layer (so with its commit record and syncs); run under
# strace fault injection by power_loss.tcl, which kills it at the Nth write to the database file.
#   tclkit tests/power_commit_child.tcl <db>
set here [file dirname [file normalize [info script]]]
source $here/power_shim.tcl
set t [store::openFile [lindex $argv 0]]
store::setCell $t.items 7 label "edited label"
store::setCell $t.items 9 gen 41
for {set i 0} {$i < 20} {incr i} { store::appendRow $t.items {id gen label w} [list [expr {900 + $i}] 1 "new $i" 1.5] }
store::commit $t
store::closeFile $t
