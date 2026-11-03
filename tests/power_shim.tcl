# Lets the power-loss tests (adapted from MK Studio's tests/test_power_loss.tcl, which speak to MK Studio's `store::` API) run against
# mkit-sql's own storage layer: every store::X they use is forwarded to ::mkitsql::db::X.
set ::env(MKIT_BACKEND) standalone
source [file join [file dirname [file normalize [info script]]] mk4load.tcl]
source [file join [file dirname [file normalize [info script]]] loadengine.tcl]
namespace eval ::store {}
foreach n {openFile closeFile commit createView appendRow setCell deleteRows layout restructure size views headerInfo repairFile} {
    proc ::store::$n {args} "::mkitsql::db::$n {*}\$args"
}
proc ::store::fetch {path props first count} { ::mkitsql::db::rows $path $props $first $count }
proc ::store::pidAlive {pid} { ::mkitsql::pidAlive $pid }
