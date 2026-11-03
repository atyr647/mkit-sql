# A correlated subquery is run once per DISTINCT set of outer values it reads (::mkitsql::memo), not once per outer row.
# Every query below is run with the shortcut on and off (::mkitsql::maxMemo 0) and the results must be identical; the shortcut
# must really have been used (memoCount), must not be used when the answer can differ between calls (RANDOM), and a query that
# was quadratic must now finish quickly.     tclsh tests/decorrelate.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_dc_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc q {sql} { mkitsql::run $sql $::db }
q "CREATE TABLE a (id INT, g INT, h INT, v DOUBLE PRECISION, s TEXT)"
q "CREATE TABLE b (id INT, g INT, h INT, w INT, s TEXT)"
expr {srand(7)}
set ra {} ; set rb {}
for {set i 1} {$i <= 400} {incr i} { lappend ra "($i, [expr {int(rand()*12)}], [expr {int(rand()*4)}], [expr {int(rand()*1000)/8.0}], 's[expr {int(rand()*5)}]')" }
for {set i 1} {$i <= 300} {incr i} { lappend rb "($i, [expr {int(rand()*15)}], [expr {int(rand()*4)}], [expr {int(rand()*50)}], 's[expr {int(rand()*5)}]')" }
q "INSERT INTO a VALUES [join $ra ,]"
q "INSERT INTO b VALUES [join $rb ,]"
q COMMIT
set queries {
    {SELECT id FROM a WHERE v > (SELECT AVG(v) FROM a a2 WHERE a2.g = a.g) ORDER BY id}
    {SELECT id FROM a WHERE v > (SELECT AVG(v) FROM a a2 WHERE a2.g % 4 = a.g % 4) ORDER BY id}
    {SELECT id FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.g = a.g AND b.w > 40) ORDER BY id}
    {SELECT id FROM a WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.g = a.g AND b.h = a.h) ORDER BY id}
    {SELECT id FROM a WHERE g IN (SELECT g FROM b WHERE b.h = a.h AND b.w > 30) ORDER BY id}
    {SELECT id FROM a WHERE g NOT IN (SELECT g FROM b WHERE b.h = a.h AND b.w > 30) ORDER BY id}
    {SELECT id FROM a WHERE v > ALL (SELECT w FROM b WHERE b.g = a.g) ORDER BY id}
    {SELECT id FROM a WHERE v > ANY (SELECT w FROM b WHERE b.g = a.g) ORDER BY id}
    {SELECT id, (SELECT COUNT(*) FROM b WHERE b.g = a.g AND b.h = a.h) AS c FROM a ORDER BY id}
    {SELECT id, (SELECT MAX(w) FROM b WHERE b.g = a.g) AS m FROM a ORDER BY id}
    {SELECT id, (SELECT SUM(w) FROM b WHERE b.g <= a.g) AS m FROM a ORDER BY id}
    {SELECT g, (SELECT COUNT(*) FROM b WHERE b.g = a.g) FROM a GROUP BY g ORDER BY g}
    {SELECT g, COUNT(*) FROM a GROUP BY g HAVING COUNT(*) > (SELECT COUNT(*) FROM b WHERE b.g = a.g) / 2 ORDER BY g}
    {SELECT id FROM a WHERE v > (SELECT AVG(v) FROM a a2 WHERE a2.g = a.g AND a2.h = (SELECT MIN(h) FROM b WHERE b.g = a.g)) ORDER BY id}
    {SELECT id FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.g = a.g AND EXISTS (SELECT 1 FROM a a3 WHERE a3.h = b.h AND a3.g = a.g AND a3.id <> a.id)) ORDER BY id}
    {SELECT x.id FROM (SELECT id, NULLIF(g, 3) AS g FROM a) x WHERE EXISTS (SELECT 1 FROM b WHERE b.g = x.g) ORDER BY x.id}
    {SELECT x.id, (SELECT COUNT(*) FROM b WHERE b.g = x.g) FROM (SELECT id, NULLIF(g, 3) AS g FROM a) x ORDER BY x.id}
    {SELECT x.id FROM (SELECT id, CASE WHEN g > 8 THEN NULL ELSE g END AS g FROM a) x WHERE x.g NOT IN (SELECT g FROM b WHERE b.h = 1) ORDER BY x.id}
    {SELECT id, s, (SELECT COUNT(*) FROM b WHERE b.s = a.s) FROM a ORDER BY id}
    {SELECT a.id FROM a JOIN b ON a.g = b.g WHERE b.w > (SELECT AVG(w) FROM b b2 WHERE b2.h = b.h) ORDER BY a.id, b.id}
    {SELECT id, SUM(v) OVER (PARTITION BY g) - (SELECT AVG(w) FROM b WHERE b.g = a.g) FROM a ORDER BY id}
    {SELECT id FROM a WHERE (g, h) IN (SELECT g, h FROM b WHERE b.w > a.id % 50) ORDER BY id}
    {SELECT id FROM a WHERE v > (SELECT AVG(v) FROM a a2 WHERE a2.id < a.id) ORDER BY id}
    {SELECT * FROM a, LATERAL (SELECT COUNT(*) AS c FROM b WHERE b.g = a.g) l ORDER BY id}
}
foreach sql $queries {
    set ::mkitsql::maxMemo 0
    set off [dict get [q $sql] rows] ; set offCount $::mkitsql::memoCount
    set ::mkitsql::maxMemo 200000
    set on [dict get [q $sql] rows] ; set onCount $::mkitsql::memoCount
    check "same result: $sql" $on $off
    check "memo off stores nothing: $sql" $offCount 0
    puts [format "%-6s %5d rows %5d remembered   %s" [expr {$on eq $off ? "ok" : "FAIL"}] [llength $on] $onCount [string range $sql 0 90]]
}
# the answer is NOT shared when it could differ between calls
set sql {SELECT id FROM a WHERE v > (SELECT RANDOM() * 125 + AVG(w) FROM b WHERE b.g = a.g)}
q $sql
check "RANDOM() inside: nothing remembered" $::mkitsql::memoCount 0
set sql {SELECT id, (SELECT COUNT(*) FROM b WHERE b.g = a.g AND RANDOM() < 2) FROM a}
q $sql
check "RANDOM() in a nested filter: nothing remembered" $::mkitsql::memoCount 0
# the bound on remembered keys: a tiny limit still gives right answers
set ::mkitsql::maxMemo 3
set small [dict get [q [lindex $queries 0]] rows]
set ::mkitsql::maxMemo 0
check "tiny memo limit" $small [dict get [q [lindex $queries 0]] rows]
set ::mkitsql::maxMemo 200000
# a statement that changes data: the memory of one statement is not used by the next
set n1 [dict get [q {SELECT COUNT(*) FROM b WHERE g = 1}] rows]
q "UPDATE b SET w = w + 100 WHERE g = 1"
set r1 [dict get [q {SELECT id, (SELECT COUNT(*) FROM b b2 WHERE b2.g = a.g AND b2.w > 100) FROM a WHERE g = 1 LIMIT 1}] rows]
check "memo is per statement" [lindex $r1 0 1] [lindex $n1 0 0]
q ROLLBACK
# the quadratic shape: 10 distinct keys over many rows (before: rows x bucket)
q "CREATE TABLE big (id INT, k INT, w INT)"
set vals {}
for {set i 0} {$i < 20000} {incr i} { lappend vals "($i, [expr {$i % 10}], [expr {$i % 97}])" }
q "INSERT INTO big VALUES [join $vals ,]"
q COMMIT
set t0 [clock milliseconds]
set r [dict get [q {SELECT COUNT(*) FROM big WHERE w > (SELECT AVG(w) FROM big b2 WHERE b2.k % 10 = big.k % 10)}] rows]
set ms [expr {[clock milliseconds] - $t0}]
puts "20,000 rows, 10 distinct keys: $r in $ms ms"
check "quadratic shape is fast" [expr {$ms < 20000}] 1
set ::mkitsql::maxMemo 0
check "and still the same answer" [dict get [q {SELECT COUNT(*) FROM big WHERE w > (SELECT AVG(w) FROM big b2 WHERE b2.k % 10 = big.k % 10)}] rows] $r
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "decorrelate: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
