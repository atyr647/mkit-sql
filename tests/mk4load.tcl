# Loads Mk4tcl for the test scripts, chosen by $MKIT_MK4TCL:
#   (unset)       the pure-Tcl stand-in in tests/vendor/mock_mk4tcl.tcl
#   builtin       Mk4tcl compiled into the running tclkit  (tclkit tests/run.tcl)
#   /path/lib.so  a Mk4tcl shared library
set _here [file dirname [file normalize [info script]]]
if {![info exists ::env(MKIT_MK4TCL)] || $::env(MKIT_MK4TCL) eq ""} {
    source $_here/vendor/mock_mk4tcl.tcl
    set ::mk4kind "stand-in"
} elseif {$::env(MKIT_MK4TCL) eq "builtin"} {
    package require Mk4tcl
    set ::mk4kind "built-in Mk4tcl [package present Mk4tcl]"
} else {
    load $::env(MKIT_MK4TCL) Mk4tcl
    set ::mk4kind "Mk4tcl library $::env(MKIT_MK4TCL)"
}
unset _here
