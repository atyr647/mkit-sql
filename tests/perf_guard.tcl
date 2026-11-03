# A coarse performance guard: representative statements over 50,000 rows must stay within generous ceilings (about 8x what a
# normal machine needs), so an accidental quadratic step or a lost pushdown fails CI instead of shipping.  It is NOT a benchmark.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/perf_guard.tcl [rows]     (PERF_SCALE=2 doubles every ceiling for slow machines)
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set N [expr {$argc > 0 ? [lindex $argv 0] : 50000}]
set scale [expr {[info exists ::env(PERF_SCALE)] ? $::env(PERF_SCALE) : 1}]
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_perf_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
proc q {sql} { mkitsql::run $sql $::db }
q "CREATE TABLE a (id INT, grp INT, val DOUBLE PRECISION, name TEXT)"
q "CREATE TABLE b (id INT, aid INT, w INT)"
for {set i 0} {$i < $N} {incr i} { mkitsql::db::appendRow $db.a {id grp val name} [list $i [expr {$i % 500}] [expr {($i * 37 % 10007) / 4.0}] "name[expr {$i * 7919 % $N}]"] }
for {set i 0} {$i < $N / 4} {incr i} { mkitsql::db::appendRow $db.b {id aid w} [list $i [expr {($i * 13) % $N}] [expr {$i % 100}]] }
q COMMIT
set target [expr {$N * 7 / 10}]
# name, ceiling in seconds, statement
set cases [list \
  point_lookup_int   0.1 "SELECT * FROM a WHERE id = $target" \
  point_lookup_text  0.1 "SELECT * FROM a WHERE name = 'name$target'" \
  count_all          0.05 "SELECT COUNT(*) FROM a" \
  count_filtered     0.15 "SELECT COUNT(*) FROM a WHERE grp = 7" \
  group_by           3   "SELECT grp, COUNT(*), SUM(val) FROM a GROUP BY grp" \
  distinct           1.6   "SELECT DISTINCT grp FROM a" \
  order_limit        3.5   "SELECT id FROM a ORDER BY val DESC, id LIMIT 10" \
  order_full         4  "SELECT id, name FROM a ORDER BY name" \
  hash_join          3  "SELECT COUNT(*) FROM a JOIN b ON a.id = b.aid WHERE b.w < 50" \
  window             7  "SELECT COUNT(*) FROM (SELECT ROW_NUMBER() OVER (PARTITION BY grp ORDER BY val) AS rn FROM a) x WHERE rn = 1" \
  update_10pct       1.2  "UPDATE a SET val = val + 1 WHERE grp < 50" \
  delete_10pct       1  "DELETE FROM a WHERE grp >= 450" \
]
set bad 0
foreach {name ceil sql} $cases {
    set best 1e18
    for {set r 0} {$r < 2} {incr r} {
        set t0 [clock microseconds] ; q $sql ; set t [expr {([clock microseconds] - $t0) / 1e6}]
        if {$name in {update_10pct delete_10pct}} { q ROLLBACK }
        if {$t < $best} { set best $t }
    }
    set limit [expr {$ceil * $scale * ($N / 50000.0 > 1 ? $N / 50000.0 : 1)}]
    set flag [expr {$best > $limit ? "SLOW" : "ok"}]
    if {$best > $limit} { incr bad }
    puts [format "%-6s %-18s %7.3f s   (ceiling %.1f s)" $flag $name $best $limit]
}
mkitsql::db::closeFile $db ; file delete $f
puts [expr {$bad ? "perf guard: $bad statement(s) over the ceiling" : "perf guard ok"}]
exit [expr {$bad ? 1 : 0}]
