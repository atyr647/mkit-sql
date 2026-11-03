# Drives the REAL MK Studio UI with mkit-sql as its query engine.
#
#   MKSTUDIO_DIR=/path/to/mkstudio-checkout xvfb-run wish tests/studio_integration.tcl
#
# A scratch copy of mkstudio is made and its loader patched to load mkit-sql
# instead of mkql.tcl; the checkout itself is not modified.  Uses the pure-Tcl
# Mk4tcl stand-in, so it checks the UI <-> engine contract, not Metakit itself.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
if {![info exists ::env(MKSTUDIO_DIR)]} { puts "set MKSTUDIO_DIR to a mkstudio checkout" ; exit 2 }
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_studio_[pid]
file delete -force $tmp ; file mkdir $tmp
file copy $::env(MKSTUDIO_DIR)/mkstudio.vfs $tmp/mkstudio.vfs
set fh [open $tmp/mkstudio.vfs/lib/app-mkstudio/loader.tcl w]
puts $fh "package require Tk 8.5
set ::mkstudio_lib \[file dirname \[info script\]\]
foreach f {theme icons menus widgets store engine} { source -encoding utf-8 \[file join \$::mkstudio_lib \$f.tcl\] }
source $root/mkitsql/mkitsql.tcl
source $root/mkitsql/engine_studio.tcl
foreach f {grid editor explorer docs app} { source -encoding utf-8 \[file join \$::mkstudio_lib \$f.tcl\] }
package provide app-mkstudio 1.0"
close $fh

set ::mkstudio_root $tmp/mkstudio.vfs
source $root/tests/mk4load.tcl
puts "(Tcl [info patchlevel], $::mk4kind)"
lappend auto_path $::mkstudio_root/lib
package require app-mkstudio
set ::env(HOME) $tmp/home ; file mkdir $::env(HOME)
::app::main {}

set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n: got <$got> want <$want>"} }

set f $tmp/demo.mk
set tag [::store::createSample $f] ; ::app::afterDbChange
proc gridpath {id n} { return "[::qdoc::docf $id].res.body.r$n" }
proc run {text} { global tag ; return [::app::newQuery $text $tag 1] }

# a plain SELECT fills a results grid
set id [run "SELECT dept, COUNT(*) AS n FROM employees GROUP BY dept ORDER BY dept"]
check nres      $::qdoc::Q($id,nres) 1
check gridrows  [::grid::count [gridpath $id 1]] 5

# two statements -> two result tabs
set id [run "SELECT 1; SELECT name FROM departments ORDER BY name"]
check twotabs   $::qdoc::Q($id,nres) 2
check secondrows [::grid::count [gridpath $id 2]] 5

# subview cell is drillable and the drill query runs through the engine
set id [run "SELECT id, name, skills FROM employees WHERE id = 1"]
check subrows   [::grid::count [gridpath $id 1]] 1
set g [gridpath $id 1]
check drillinfo [dict get $::grid::G($g,drill)] {2 skills}
set before [llength [array names ::app::A type,*]]
::qdoc::drill $id r1 0 skills
check drillopened [expr {[llength [array names ::app::A type,*]] > $before}] 1

# editing statements change the database and mark it dirty
set id [run "UPDATE products SET stock = stock + 1 WHERE sku = 'MK-001'"]
check dirty     [expr {[::store::dirty $tag] > 0}] 1
check updated   [lindex [::store::rows $tag.products {stock} 0 1] 0 0] 141
run "ROLLBACK"
check rolledback [lindex [::store::rows $tag.products {stock} 0 1] 0 0] 140

# a syntax error is reported with a position and marks the editor
set id [run "SELECT id FROM employees WHERE id = = 3"]
check synerr_nores $::qdoc::Q($id,nres) 0
check synerr_mark  [llength [[::qdoc::docf $id].ed.t tag ranges err]] 2

# a runtime error stops the script and does not produce a grid
set id [run "SELECT 1; SELECT nope FROM employees; SELECT 3"]
check rterr  $::qdoc::Q($id,nres) 1

# row cap message path
set ::engine::maxRows 3
set id [run "SELECT id FROM employees"]
check capped [::grid::count [gridpath $id 1]] 3
set ::engine::maxRows 100000

# editor highlighting / completion tables come from the engine
check kw [expr {[lsearch -exact $::engine::keywords SELECT] >= 0}] 1
check fn [expr {[lsearch -exact $::engine::functions UPPER] >= 0}] 1

puts "$pass passed, $fail failed"
file delete -force $tmp
exit [expr {$fail ? 1 : 0}]
