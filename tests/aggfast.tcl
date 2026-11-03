# The chunk-at-a-time aggregate fold must give what the row-at-a-time fold gives (::mkitsql::fastAgg 0): whole numbers exactly, real numbers up
# to rounding in the last digits (the order of additions differs), under big and tiny memory budgets.   tclsh tests/aggfast.tcl [rounds]
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set rounds [expr {$argc > 0 ? [lindex $argv 0] : 60}]
expr {srand(17)}
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_af_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" } }
proc q {sql} { mkitsql::run $sql $::db }
q "CREATE TABLE t (id INT, g INT, h TEXT, i INT, big BIGINT, d DOUBLE PRECISION)"
set n 3000 ; set rows {}
for {set k 1} {$k <= $n} {incr k} {
    lappend rows [list $k [expr {int(rand()*13)}] "h[expr {int(rand()*4)}]" [expr {int(rand()*2000) - 1000}] [expr {int(rand()*4000000000)}] [expr {(rand() - 0.5) * 1000}]]
}
mkitsql::insertRows $db t {} $rows
q COMMIT
proc same {a b} {
    if {[llength $a] != [llength $b]} { return 0 }
    foreach x $a y $b {
        if {[llength $x] > 1 || [llength $y] > 1} { if {![same $x $y]} { return 0 } ; continue }
        if {$x eq $y} continue
        if {[string is double -strict $x] && [string is double -strict $y] && abs($x - $y) <= 1e-9 * max(1.0, abs($x), abs($y))} continue
        return 0
    }
    return 1
}
set queries {
    {SELECT COUNT(*), COUNT(i), SUM(i), AVG(i), MIN(i), MAX(i) FROM t}
    {SELECT SUM(d), AVG(d), MIN(d), MAX(d) FROM t}
    {SELECT SUM(big), MIN(big), MAX(big), AVG(big) FROM t}
    {SELECT g, COUNT(*), SUM(i), AVG(d), MIN(d), MAX(i) FROM t GROUP BY g ORDER BY g}
    {SELECT g, h, COUNT(*), SUM(big), MAX(d) FROM t GROUP BY g, h ORDER BY g, h}
    {SELECT h, SUM(i + 1), MIN(i * 2), COUNT(NULLIF(i, 0)) FROM t GROUP BY h ORDER BY h}
    {SELECT g, SUM(NULLIF(i, 5)), AVG(NULLIF(d, 0.5)), COUNT(NULLIF(g, 3)) FROM t GROUP BY g ORDER BY g}
    {SELECT SUM(i) FROM t WHERE id < 0}
    {SELECT g, MIN(h), MAX(h), COUNT(*) FROM t GROUP BY g ORDER BY g}
    {SELECT id % 7, SUM(d), COUNT(DISTINCT g), SUM(i) FROM t GROUP BY id % 7 ORDER BY 1}
    {SELECT COUNT(*) FROM (SELECT g, SUM(i) AS s FROM t GROUP BY g HAVING SUM(i) > 0) x}
    {SELECT g, SUM(i) FILTER (WHERE d > 0), COUNT(*) FILTER (WHERE i > 0) FROM t GROUP BY g ORDER BY g}
}
foreach budget {"" "800" "50"} {
    if {$budget ne ""} { set ::mkitsql::memBytes $budget ; set ::mkitsql::chunk 7 }
    foreach sql $queries {
        set ::mkitsql::fastAgg 0 ; set slow [dict get [q $sql] rows]
        set ::mkitsql::fastAgg 1 ; set fast [dict get [q $sql] rows]
        check "budget [expr {$budget eq {} ? {default} : $budget}]: $sql" [same $fast $slow] 1
    }
}
# the fast path was really taken
set ::mkitsql::fastAgg 1
set i [mkitsql::aggNew [dict create ng 0 gkey "" aargs "" specs [list [list sum 0 0 -1 n]]]]
check "eligible" $::mkitsql::S($i,fast) 1
set i [mkitsql::aggNew [dict create ng 0 gkey "" aargs "" specs [list [list sum 0 0 -1 i]]]]
check "intervals are not" $::mkitsql::S($i,fast) 0
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "aggregate fast path: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
