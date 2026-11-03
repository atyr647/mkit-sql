# Test knobs for the memory budget:  MKIT_MEMBYTES=1500 MKIT_CHUNK=7 tclsh tests/run.tcl
# A tiny budget forces every sort, aggregate, join, DISTINCT and window to spill to temporary files,
# so the whole suite doubles as a test of the out-of-memory paths.
if {[info exists ::env(MKIT_MEMBYTES)] && $::env(MKIT_MEMBYTES) ne ""} { set ::mkitsql::memBytes $::env(MKIT_MEMBYTES) }
if {[info exists ::env(MKIT_CHUNK)] && $::env(MKIT_CHUNK) ne ""} { set ::mkitsql::chunk $::env(MKIT_CHUNK) }
if {[info exists ::env(MKIT_MEMBYTES)] && $::env(MKIT_MEMBYTES) ne ""} { puts "(memory budget $::mkitsql::memBytes bytes, chunk $::mkitsql::chunk)" }
