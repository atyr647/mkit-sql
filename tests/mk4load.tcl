# Loads Mk4tcl for the test scripts, chosen by $MKIT_MK4TCL:
#   (unset)       the pure-Tcl stand-in in tests/vendor/mock_mk4tcl.tcl
#   builtin       Mk4tcl compiled into the running tclkit  (tclkit tests/run.tcl)
#   /path/lib.so  a Mk4tcl shared library
#
# Inside a tclkit the real Mk4tcl is already loaded (the kit reads its own files through it), so the
# stand-in is never used there: the stand-in would replace the ::mk commands the kit depends on.
set _here [file dirname [file normalize [info script]]]
set _want [expr {[info exists ::env(MKIT_MK4TCL)] ? $::env(MKIT_MK4TCL) : ""}]
if {$_want eq "" && [llength [info commands ::mk::file]]} { set _want builtin }
if {$_want eq ""} {
    source $_here/vendor/mock_mk4tcl.tcl
    set ::mk4kind "stand-in"
} elseif {$_want eq "builtin"} {
    package require Mk4tcl
    set ::mk4kind "built-in Mk4tcl [package present Mk4tcl]"
} else {
    load $_want Mk4tcl
    set ::mk4kind "Mk4tcl library $_want"
}
unset _here _want
