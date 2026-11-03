# Timing and memory at scale:  MKIT_MK4TCL=... tclsh tests/scale.tcl [rows]
# Not part of the pass/fail suite; it prints a table so regressions are easy to spot.
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/vendor/store.tcl
source [file join [file dirname $here] mkitsql mkitsql.tcl]
set n [expr {$argc ? [lindex $argv 0] : 200000}]
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_scale_[pid].mk
file delete $f
set db [store::openFile $f -create]
store::createView $db big {{id I {}} {grp I {}} {val D {}} {name S {}} {day S {}}}
store::createView $db small {{id I {}} {label S {}}}
set t0 [clock milliseconds]
for {set i 0} {$i < $n} {incr i} {
    store::appendRow $db.big {id grp val name day} [list $i [expr {$i % 1000}] [expr {($i * 37 % 10007) / 4.0}] "name[expr {$i % 5000}]" [format 2026-%02d-%02d [expr {1 + $i % 12}] [expr {1 + $i % 28}]]]
}
for {set i 0} {$i < 1000} {incr i} { store::appendRow $db.small {id label} [list $i "L$i"] }
puts [format "loaded %d rows in %d ms" $n [expr {[clock milliseconds] - $t0}]]
proc rss {} { set fh [open /proc/self/status] ; set s [read $fh] ; close $fh ; regexp {VmHWM:\s+(\d+)} $s -> kb ; return [expr {$kb / 1024}] }
proc t {sql} {
    set t0 [clock milliseconds]
    if {[catch {mkitsql::run $sql $::db} r]} { puts [format "%7s  ERROR %s" "-" $r] ; return }
    set rows [expr {[dict exists $r rows] ? [llength [dict get $r rows]] : [dict get $r affected]}]
    puts [format "%6d ms  %7d rows  %s" [expr {[clock milliseconds] - $t0}] $rows $sql]
}
t "SELECT COUNT(*) FROM big"
t "SELECT * FROM big WHERE id = 123456"
t "SELECT * FROM big WHERE grp = 7"
t "SELECT * FROM big LIMIT 100"
t "SELECT grp, COUNT(*), AVG(val), MAX(name) FROM big GROUP BY grp"
t "SELECT * FROM big ORDER BY val DESC LIMIT 10"
t "SELECT name FROM big ORDER BY name LIMIT 10"
t "SELECT DISTINCT name FROM big"
t "SELECT s.label, COUNT(*) FROM big b JOIN small s ON b.grp = s.id GROUP BY s.label"
t "SELECT COUNT(*) FROM big b WHERE EXISTS (SELECT 1 FROM small s WHERE s.id = b.grp)"
t "SELECT id, SUM(val) OVER (PARTITION BY grp ORDER BY id) FROM big WHERE id < 50000 ORDER BY id LIMIT 5"
t "SELECT grp, ROW_NUMBER() OVER (ORDER BY SUM(val) DESC) FROM big GROUP BY grp"
t "SELECT day, COUNT(*) FROM big WHERE CAST(day AS DATE) >= DATE '2026-06-01' GROUP BY day ORDER BY day LIMIT 3"
t "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000) SELECT COUNT(*) FROM c"
t "UPDATE big SET val = val + 1 WHERE grp = 5"
t "DELETE FROM big WHERE grp = 6"
t "INSERT INTO small SELECT id + 1000, name FROM big WHERE id < 20000"
puts "peak memory: [rss] MB"
store::closeFile $db ; file delete $f
