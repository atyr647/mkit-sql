# mkit-sql side of the benchmark: tclkit with real Metakit.   tclkit tests/bench/bench.tcl <rows> <out.json>
set here [file dirname [file normalize [info script]]]
set root [file dirname [file dirname $here]]
set ::env(MKIT_BACKEND) standalone
source $root/tests/mk4load.tcl
source $root/tests/loadengine.tcl
lassign $argv N out
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_bench_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
proc q {sql} { mkitsql::run $sql $::db }
proc ms {script} { set t0 [clock microseconds] ; uplevel 1 $script ; return [expr {([clock microseconds] - $t0) / 1000.0}] }
set res {}
proc rec {name t} { global res ; lappend res "\"$name\": [format %.2f $t]" ; puts [format "%-34s %10.1f ms" $name $t] }
q "CREATE TABLE a (id INT, grp INT, val DOUBLE PRECISION, name TEXT, tag TEXT)"
q "CREATE TABLE b (id INT, aid INT, w INT)"
rec load_a [ms {
    for {set i 0} {$i < $N} {incr i} { mkitsql::db::appendRow $db.a {id grp val name tag} [list $i [expr {$i % 1000}] [expr {($i * 37 % 10007) / 4.0}] "name[expr {$i * 7919 % $N}]" "t[expr {$i % 50}]"] }
    q COMMIT
}]
rec load_b [ms {
    for {set i 0} {$i < $N / 4} {incr i} { mkitsql::db::appendRow $db.b {id aid w} [list $i [expr {($i * 13) % $N}] [expr {$i % 100}]] }
    q COMMIT
}]
set target [expr {$N * 7 / 10}]
set queries [list \
  point_lookup_int     "SELECT * FROM a WHERE id = $target" \
  point_lookup_text    "SELECT * FROM a WHERE name = 'name$target'" \
  range_10_rows        "SELECT * FROM a WHERE id BETWEEN $target AND [expr {$target + 9}]" \
  count_all            "SELECT COUNT(*) FROM a" \
  count_filtered       "SELECT COUNT(*) FROM a WHERE grp = 7" \
  sum_avg              "SELECT SUM(val), AVG(val), MIN(id), MAX(id) FROM a" \
  group_by_1000        "SELECT grp, COUNT(*), SUM(val) FROM a GROUP BY grp" \
  distinct_tag         "SELECT DISTINCT tag FROM a" \
  order_by_limit_10    "SELECT id FROM a ORDER BY val DESC, id LIMIT 10" \
  order_by_full        "SELECT id, name FROM a ORDER BY name" \
  join_hash            "SELECT COUNT(*) FROM a JOIN b ON a.id = b.aid WHERE b.w < 50" \
  like_prefix          "SELECT COUNT(*) FROM a WHERE name LIKE 'name12%'" \
  window_row_number    "SELECT COUNT(*) FROM (SELECT ROW_NUMBER() OVER (PARTITION BY grp ORDER BY val) AS rn FROM a) x WHERE rn = 1" \
  correlated_subquery  "SELECT COUNT(*) FROM b WHERE w > (SELECT AVG(w) FROM b b2 WHERE b2.aid % 10 = b.aid % 10)" \
]
foreach {name sql} $queries {
    set best 1e18
    for {set r 0} {$r < 3} {incr r} { set t [ms {q $sql}] ; if {$t < $best} { set best $t } }
    rec $name $best
}
rec insert_10k_rows [ms { set v {} ; for {set i 0} {$i < 10000} {incr i} { lappend v "([expr {$N + $i}], 1, 1.5, 'x', 't1')" } ; q "INSERT INTO a VALUES [join $v ,]" ; q COMMIT }]
rec update_10pct [ms { q "UPDATE a SET val = val + 1 WHERE grp < 100" ; q COMMIT }]
rec delete_10pct [ms { q "DELETE FROM a WHERE grp >= 900" ; q COMMIT }]
mkitsql::db::closeFile $db
set fh [open $out w] ; puts $fh "\{[join $res ,]\}" ; close $fh
if {![catch {set h [open /proc/self/status] ; set st [read $h] ; close $h}] && [regexp {VmHWM:\s+(\d+)} $st -> kb]} { puts "peak memory (VmHWM): [expr {$kb / 1024}] MB" }
puts "file size: [expr {[file size $f] / 1048576}] MB" ; file delete $f
