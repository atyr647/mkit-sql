# Child for tests/locking.tcl: opens a file through MK Studio's own store.tcl (not mkit-sql) and holds it.
#   tclsh locking_child_studio.tcl <store.tcl> <dbfile>
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
lassign $argv storeTcl f
source $storeTcl
fconfigure stdout -buffering line
if {[catch {::store::openFile $f -create} tag opts]} { puts "LOCKED [dict get $opts -errorcode]" ; exit 0 }
puts "WON [pid]"
gets stdin
::store::closeFile $tag
puts "CLOSED"
