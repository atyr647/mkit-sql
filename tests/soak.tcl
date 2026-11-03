# Soak test: run many mixed statements (reads, writes, rollbacks, errors, spills) in ONE process and check that nothing
# accumulates: engine state arrays must return to their size, no spill files remain, and memory (RSS, Linux) must not keep growing.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/soak.tcl [seconds] [seed]
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set secs [expr {$argc > 0 ? [lindex $argv 0] : 60}]
expr {srand([expr {$argc > 1 ? [lindex $argv 1] : 1}])}
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_soak_[pid].mk
file delete $f
set db [store::createSample $f]
store::commit $db
set mkitsql::memBytes 30000 ; set mkitsql::chunk 50          ;# small budget: operators spill all the time
proc rss {} { if {[catch {set h [open /proc/self/status] ; set d [read $h] ; close $h}] || ![regexp {VmRSS:\s+(\d+)} $d -> kb]} { return 0 } ; return $kb }
set corpus {
 "SELECT dept, COUNT(*), AVG(salary) FROM employees GROUP BY dept ORDER BY 1"
 "SELECT e.name, d.name FROM employees e LEFT JOIN departments d ON d.id = e.dept ORDER BY 1"
 "SELECT name FROM employees WHERE salary > (SELECT AVG(salary) FROM employees) ORDER BY name"
 "SELECT id, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) FROM employees"
 "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 300) SELECT SUM(x) FROM n"
 "SELECT DISTINCT dept FROM employees UNION SELECT id FROM departments ORDER BY 1"
 "SELECT x FROM (VALUES (1), (2), (3)) t(x) WHERE x IN (SELECT dept FROM employees)"
 "INSERT INTO products (sku, name, price, stock) VALUES ('S-1', 'Soak', 1.5, 7)"
 "UPDATE products SET stock = stock + 1"
 "DELETE FROM products WHERE stock > 100"
 "CREATE TABLE soak AS SELECT * FROM employees"
 "DROP TABLE IF EXISTS soak"
 "SELECT nonsense FROM nowhere"
 "SELECT 1 / 0"
 "SELEC 1"
 "ROLLBACK"
}
proc stateSize {} { return [expr {[array size ::mkitsql::S] + [array size ::mkitsql::plans] + [array size ::mkitsql::derivedBq] + [llength [info procs ::mkitsql::cx::*]]}] }
set t0 [clock seconds] ; set n 0 ; set samples {} ; set maxState 0
while {[clock seconds] - $t0 < $secs} {
    set sql [lindex $corpus [expr {int(rand() * [llength $corpus])}]]
    catch {mkitsql::run $sql $db}
    incr n
    if {$n % 20 == 0} { catch {mkitsql::run ROLLBACK $db} }
    if {$n % 200 == 0} {
        set st [stateSize] ; if {$st > $maxState} { set maxState $st }
        lappend samples [rss]
    }
}
catch {mkitsql::run ROLLBACK $db}
set leftover [llength [glob -nocomplain -directory [mkitsql::tmpDir] mkitsql-*-[pid]-*]]
set fail 0
# state after a statement: nothing may stay behind
if {[stateSize] > 5} { puts "FAIL engine state not released: [stateSize]" ; incr fail }
if {$leftover} { puts "FAIL temp folders left: $leftover" ; incr fail }
# memory: compare the second half of the run with the first quarter after warm-up (allow some noise)
set k [llength $samples]
if {$k >= 8 && [lindex $samples 0] > 0} {
    set early [lindex $samples [expr {$k / 4}]] ; set late [lindex $samples end]
    set growth [expr {$late - $early}]
    puts "statements: $n   RSS early [expr {$early / 1024}] MB, late [expr {$late / 1024}] MB (growth [expr {$growth / 1024}] MB), peak engine state entries $maxState"
    if {$growth > 20 * 1024} { puts "FAIL memory grew by more than 20 MB" ; incr fail }
} else { puts "statements: $n (too short to judge memory)" }
store::closeFile $db ; file delete $f
puts [expr {$fail ? "soak FAILED" : "soak ok"}]
exit [expr {$fail ? 1 : 0}]
