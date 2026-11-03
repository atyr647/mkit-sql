# Runs MK Studio's own engine contract test (tests/engine_contract.tcl in the mkstudio repo)
# against mkit-sql, unmodified except that mkit-sql is loaded after the built-in dialect.
#
#   MKSTUDIO_DIR=/path/to/mkstudio tclsh tests/studio_contract.tcl
#   MKIT_MK4TCL=/path/to/Mk4tcl.so MKSTUDIO_DIR=... tclsh tests/studio_contract.tcl     (real Metakit)
set root [file dirname [file dirname [file normalize [info script]]]]
if {![info exists ::env(MKSTUDIO_DIR)]} { puts "set MKSTUDIO_DIR to a mkstudio checkout" ; exit 2 }
set mks $::env(MKSTUDIO_DIR)
set fh [open $mks/tests/engine_contract.tcl] ; set text [read $fh] ; close $fh
if {[info exists ::env(MKIT_MK4TCL)] && $::env(MKIT_MK4TCL) eq "builtin"} { set ::env(REAL_MK) 1 } elseif {[info exists ::env(MKIT_MK4TCL)] && $::env(MKIT_MK4TCL) ne ""} {
    set text [string map [list {if {![info exists ::env(REAL_MK)]} { source $here/mock_mk4tcl.tcl } else { package require Mk4tcl }} "load \$::env(MKIT_MK4TCL) Mk4tcl"] $text]
}
set text [string map [list \
    {set here [file dirname [file normalize [info script]]]} "set here $mks/tests" \
    {# source $here/../../my-sql-engine/engine.tcl} "source $root/mkitsql/mkitsql.tcl\nsource $root/mkitsql/engine_studio.tcl" \
    {/tmp/contract.mk} "[expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : {/tmp}}]/mkitsql_contract_[pid].mk"] $text]
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_contract_run_[pid].tcl
set fh [open $tmp w] ; puts -nonewline $fh $text ; close $fh
source $tmp
