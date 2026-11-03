# `package require mkitsql` works when the mkitsql directory is on auto_path.
set root [file dirname [file dirname [file normalize [info script]]]]
source $root/tests/vendor/mock_mk4tcl.tcl
source $root/tests/vendor/store.tcl
lappend auto_path $root
package require mkitsql
puts "mkitsql [package present mkitsql] loaded; SELECT 1+1 => [lindex [dict get [mkitsql::run {SELECT 1 + 1}] rows] 0 0]"
