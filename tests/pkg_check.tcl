# `package require mkitsql` works when the mkitsql directory is on auto_path - on its own (standalone
# storage layer, nothing from MK Studio) or next to MK Studio's store.tcl.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/pkg_check.tcl [studio|standalone]
set root [file dirname [file dirname [file normalize [info script]]]]
source $root/tests/mk4load.tcl
set mode [expr {$argc ? [lindex $argv 0] : "standalone"}]
if {$mode eq "studio"} { source $root/tests/vendor/store.tcl }
lappend auto_path $root
package require mkitsql
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_pkg_[pid].mk
file delete $f
set db [expr {$mode eq "studio" ? [::store::openFile $f -create] : [::mkitsql::db::openFile $f -create]}]
::mkitsql::run {CREATE TABLE players (id INT, name VARCHAR(20), score DOUBLE PRECISION, items TABLE (item TEXT, qty INT))} $db
::mkitsql::run {INSERT INTO players (id, name, score) VALUES (1, 'Ada', 9.5), (2, 'Bob', 7)} $db
::mkitsql::run {COMMIT} $db
set r [::mkitsql::query {SELECT name, score FROM players WHERE score > ? ORDER BY score DESC} $db {8}]
if {[dict get $r rows] ne {{Ada 9.5}}} { puts "FAIL: [dict get $r rows]" ; exit 1 }
puts "mkitsql [package present mkitsql] loaded ($::mkitsql::backend storage); SELECT 1+1 => [lindex [dict get [::mkitsql::run {SELECT 1 + 1}] rows] 0 0]; README example ok"
if {$mode eq "studio"} { ::store::closeFile $db } else { ::mkitsql::db::closeFile $db }
file delete $f
