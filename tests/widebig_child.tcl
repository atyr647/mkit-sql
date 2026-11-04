# child of widebig.tcl: add N rows of 1 MiB to column b3 of table t in one commit; says COMMITTING just before it, so the parent can kill it in the middle
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv f n base
set db [mkitsql::db::openFile $f]
set mkitsql::db::durable 0
set pad [string repeat y 1048560]
for {set i 0} {$i < $n} {incr i} { mkitsql::db::appendRow $db.t {k b3} [list [expr {$base + $i}] "[format %08d [expr {$base + $i}]]$pad"] }
puts COMMITTING ; flush stdout
mkitsql::db::commit $db
puts DONE ; flush stdout
mkitsql::db::closeFile $db
