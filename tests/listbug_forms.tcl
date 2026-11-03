# The string form the engine gives a list whose first element starts with '#' (see ::mkitsql::rt::sk) must be exactly the string
# a healthy Tcl writes, for every short string over an alphabet of the characters that matter.
#   healthy-tclsh tests/listbug_forms.tcl dump /tmp/canon.txt        (on a Tcl without the bug)
#   tclkit tests/listbug_forms.tcl check /tmp/canon.txt              (on the runtime under test; MKIT_MK4TCL=builtin)
set here [file dirname [file normalize [info script]]]
lassign $argv mode file
set alpha [list # \] \[ \{ \} \\ " " x ";" "\""]
proc gen {n} { global alpha ; if {$n == 0} { return {{}} } ; set o {} ; foreach p [gen [expr {$n-1}]] { foreach c $alpha { lappend o $p$c } } ; return $o }
proc hx {s} { binary scan [encoding convertto utf-8 $s] H* h ; return $h }
if {$mode eq "dump"} {
    set out [open $file w]
    foreach n {1 2 3 4 5} { foreach s [gen $n] { puts $out [hx [list $s]] } }
    close $out
    exit 0
}
source $here/mk4load.tcl
source $here/loadengine.tcl
set in [open $file r] ; set tot 0 ; set bad 0
foreach n {1 2 3 4 5} { foreach s [gen $n] {
    gets $in want
    incr tot
    if {[hx [::mkitsql::rt::sk [list $s]]] ne $want} { incr bad ; if {$bad < 6} { puts "DIFF [list $s]" } }
    set l2 [::mkitsql::rt::sk [list $s tail "x y"]]
    if {[llength $l2] != 3 || [lindex $l2 0] ne $s || [lindex $l2 1] ne "tail" || [lindex $l2 2] ne "x y"} { incr bad ; puts "NOT THE SAME LIST: [list $s]" }
} }
close $in
puts "list forms: $tot strings checked (listBug=$::mkitsql::listBug), $bad differ from a healthy Tcl"
exit [expr {$bad ? 1 : 0}]
