# child of commit_crash.tcl: a commit that stops dead (exit, nothing cleaned up) at one named step.
#   args: file step mode     mode kill = the files stay as the process left them; power = the commit record is first put into what the
#   model of commit_model.tcl says was durable at that moment
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/commit_model.tcl
lassign $argv path step mode
set ::modelRec $path.commit
set ::stopStep $step ; set ::stopMode $mode
proc stopAt {name} {
    if {$name ne $::stopStep} return
    if {$::stopMode eq "power"} powerCut
    exit 42
}
set db [mkitsql::db::openFile $path]
for {set i 50} {$i < 75} {incr i} { mkitsql::db::appendRow $db.t k $i }
set mkitsql::db::commitHook stopAt
mkitsql::db::commit $db
mkitsql::db::closeFile $db
