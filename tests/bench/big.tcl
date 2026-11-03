# Tens of millions of rows of a narrow table on real Metakit, bounded memory.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/bench/big.tcl <rows>
set here [file dirname [file normalize [info script]]]
set root [file dirname [file dirname $here]]
set ::env(MKIT_BACKEND) standalone
source $root/tests/mk4load.tcl
source $root/tests/loadengine.tcl
set N [lindex $argv 0]
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_big_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
proc q {sql} { mkitsql::run $sql $::db }
proc ms {script} { set t0 [clock microseconds] ; uplevel 1 $script ; return [expr {([clock microseconds] - $t0) / 1000.0}] }
proc rss {what} { set fh [open /proc/self/status] ; set s [read $fh] ; close $fh ; regexp "$what:\\s+(\\d+)" $s -> kb ; return [expr {$kb / 1024}] }
q "CREATE TABLE a (id INT, grp INT, val DOUBLE PRECISION)"
puts [format "%-30s %10.1f s   file %d MB  peak %d MB" load [expr {[ms {
    for {set i 0} {$i < $N} {incr i} {
        mkitsql::db::appendRow $db.a {id grp val} [list $i [expr {$i % 1000}] [expr {($i * 37 % 10007) / 4.0}]]
        if {$i % 2000000 == 1999999} { q COMMIT }
    }
    q COMMIT
}] / 1000.0}] [expr {[file size $f] / 1048576}] [rss VmHWM]]
set tests [list \
  "count(*)"            "SELECT COUNT(*) FROM a" \
  "point lookup"        "SELECT * FROM a WHERE id = [expr {$N * 7 / 10}]" \
  "count where grp=7"   "SELECT COUNT(*) FROM a WHERE grp = 7" \
  "sum/avg/min/max"     "SELECT SUM(val), AVG(val), MIN(id), MAX(id) FROM a" \
  "group by 1000"       "SELECT grp, COUNT(*), SUM(val) FROM a GROUP BY grp" \
  "distinct grp"        "SELECT DISTINCT grp FROM a" \
  "order by .. limit 10" "SELECT id FROM a ORDER BY val DESC, id LIMIT 10" \
  "count(distinct id)"  "SELECT COUNT(DISTINCT id) FROM a" ]
foreach {name sql} $tests {
    set t [ms {set r [q $sql]}]
    puts [format "%-30s %10.1f s   rows %-6d peak %d MB" $name [expr {$t / 1000.0}] [llength [dict get $r rows]] [rss VmHWM]]
}
puts [format "%-30s %10.1f s   peak %d MB" "update 10%" [expr {[ms {q "UPDATE a SET val = val + 1 WHERE grp < 100" ; q COMMIT}] / 1000.0}] [rss VmHWM]]
puts [format "%-30s %10.1f s   peak %d MB" "delete 10%" [expr {[ms {q "DELETE FROM a WHERE grp >= 900" ; q COMMIT}] / 1000.0}] [rss VmHWM]]
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
