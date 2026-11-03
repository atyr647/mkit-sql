# Test knobs:  MKIT_MEMBYTES=1500 MKIT_CHUNK=7 tclsh tests/run.tcl     (memory budget, chunk size)
#              MKIT_BULKMIN=1 tclsh tests/run.tcl                       (always rebuild tables for big deletes/updates)
# A tiny budget forces every sort, aggregate, join, DISTINCT and window to spill to temporary files,
# so the whole suite doubles as a test of the out-of-memory paths.
if {[info exists ::env(MKIT_MEMBYTES)] && $::env(MKIT_MEMBYTES) ne ""} { set ::mkitsql::memBytes $::env(MKIT_MEMBYTES) }
if {[info exists ::env(MKIT_CHUNK)] && $::env(MKIT_CHUNK) ne ""} { set ::mkitsql::chunk $::env(MKIT_CHUNK) }
if {[info exists ::env(MKIT_MEMBYTES)] && $::env(MKIT_MEMBYTES) ne ""} { puts "(memory budget $::mkitsql::memBytes bytes, chunk $::mkitsql::chunk)" }
if {[info exists ::env(MKIT_BULKMIN)] && $::env(MKIT_BULKMIN) ne ""} { set ::mkitsql::bulkMin $::env(MKIT_BULKMIN) }
