# Regression tests for the findings of the independent review of the 0.4 SQL additions (windows with grouping sets, recursive CTEs with subqueries,
# RANGE frames with NULL keys, COLLATE edges, interval equality and scaling, NATURAL JOIN on duplicate names, guards).   tclsh tests/review2.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_rv2_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" } }
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }
proc err {sql} { if {[catch {q $sql} e]} { return $e } ; return "" }
q "CREATE TABLE t (a TEXT, b TEXT, c INT, v INT)"
q "INSERT INTO t VALUES ('x','p',1,10),('x','q',1,20),('y','p',2,30),('y','p',2,40),('z','q',3,50)"
q "CREATE TABLE u (k TEXT, w INT)" ; q "INSERT INTO u VALUES ('x',1),('y',2),('y',3),('q',9)"
q COMMIT
# windows + grouping sets are refused instead of computed per set
check "window with ROLLUP refused" [string match "*cannot be combined with ROLLUP*" [err "SELECT a, SUM(v), RANK() OVER (ORDER BY SUM(v)) FROM t GROUP BY ROLLUP(a)"]] 1
check "... and works on the result of a subquery" [rows "SELECT a, s, RANK() OVER (ORDER BY s DESC) FROM (SELECT a, SUM(v) AS s FROM t GROUP BY ROLLUP(a)) x ORDER BY 3, 1"] {{NULL 150 1} {y 70 2} {z 50 3} {x 30 4}}
check "RANDOM with grouping sets refused" [string match "*RANDOM() cannot be used*" [err "SELECT a, SUM(RANDOM()) FROM t GROUP BY ROLLUP(a)"]] 1
check "too many sets" [string match "*limit is 256*" [err "SELECT 1 FROM t GROUP BY CUBE(a,b), CUBE(c,v), CUBE(a||b,a||c), CUBE(b||c,b||v), CUBE(a||v,c+1)"]] 1
check "CUBE of 9" [string match "*more than 8*" [err "SELECT 1 FROM t GROUP BY CUBE(a,b,c,v,a||b,a||c,a||v,b||c,b||v)"]] 1
check "x IN (SELECT ..) with a grouped x" [rows "SELECT a FROM t GROUP BY ROLLUP(a) HAVING a IN (SELECT k FROM u) ORDER BY a"] {x y}
# recursive CTE: subquery answers belong to one round
check "recursive term with a correlated subquery" [rows "WITH RECURSIVE r(n,g) AS (SELECT 1,0 UNION ALL SELECT n+1,g FROM r WHERE n<6 AND (SELECT MAX(n) FROM r r2 WHERE r2.g=r.g) < 3) SELECT n FROM r ORDER BY n"] {1 2 3}
check "recursive term with an uncorrelated subquery" [rows "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<5 AND (SELECT MAX(n) FROM r r2) < 3) SELECT n FROM r"] {1 2 3}
# RANGE frames and NULL keys
set v "(VALUES (1,NULL,10),(2,5,1),(3,7,2)) t(id,o,x)"
check "RANGE ... 1 PRECEDING reaches the NULL rows" [rows "SELECT id, SUM(x) OVER (ORDER BY o RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) FROM $v ORDER BY id"] {{1 10} {2 10} {3 11}}
check "RANGE 1 FOLLOWING ... NULLS LAST" [rows "SELECT id, SUM(x) OVER (ORDER BY o NULLS LAST RANGE BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) FROM $v ORDER BY id"] {{1 10} {2 12} {3 10}}
# COLLATE
check "ORDER BY position COLLATE refused" [string match "*COLLATE is only supported*" [err "SELECT a FROM t ORDER BY 1 COLLATE NOCASE"]] 1
check "SIMILAR TO ... COLLATE NOCASE" [rows "SELECT DISTINCT a FROM t WHERE a COLLATE NOCASE SIMILAR TO 'X%'"] x
check "DISTINCT with COLLATE refused" [string match "*COLLATE is not supported in SELECT DISTINCT*" [err "SELECT DISTINCT a COLLATE NOCASE FROM t"]] 1
check "multi-character ESCAPE refused" [string match "*one character*" [err "SELECT 'a' LIKE 'a' ESCAPE 'ab'"]] 1
check "very long SIMILAR TO pattern refused" [string match "*longer than 2000*" [err "SELECT 'a' SIMILAR TO '[string repeat a| 1500]b'"]] 1
check "duplicate WINDOW name" [string match "*defined twice*" [err "SELECT SUM(v) OVER w FROM t WINDOW w AS (ORDER BY v), w AS (ORDER BY v)"]] 1
# intervals
check "1 mon is not 30 days, anywhere" [rows "SELECT INTERVAL '1' MONTH = INTERVAL '30' DAY, INTERVAL '1' MONTH IN (INTERVAL '30' DAY), INTERVAL '1' MONTH < INTERVAL '31' DAY"] {{0 0 1}}
check "<> on intervals" [rows "SELECT INTERVAL '1' DAY <> INTERVAL '24' HOUR, INTERVAL '1' MONTH <> INTERVAL '30' DAY"] {{0 1}}
check "join on intervals agrees" [rows "SELECT COUNT(*) FROM (SELECT INTERVAL '1' MONTH AS i) a JOIN (SELECT INTERVAL '30' DAY AS i) b ON a.i = b.i"] 0
check "AVG of months keeps the fraction" [rows "SELECT AVG(i) FROM (SELECT INTERVAL '1' MONTH AS i UNION ALL SELECT INTERVAL '2' MONTH) x"] {{{1 mon 15 days}}}
check "interval / n and * n" [rows "SELECT INTERVAL '1' MONTH / 3, INTERVAL '1' MONTH * 0.5, INTERVAL '2' DAY * 2, INTERVAL '3' MONTH / 3"] {{{10 days} {15 days} {4 days} {1 mon}}}
check "interval where a number is expected" [string match "*interval cannot be used as a number*" [err "SELECT SUM(CASE WHEN v < 30 THEN INTERVAL '1' DAY ELSE 5 END) FROM t"]] 1
# NATURAL JOIN on a duplicated name
check "NATURAL JOIN on duplicated names is ambiguous" [string match "*NATURAL JOIN on 'k' is ambiguous*" [err "SELECT * FROM (SELECT a.k, b.k FROM u a JOIN u b ON a.w = b.w) q NATURAL JOIN u"]] 1
# whole numbers beyond a double's precision sort exactly even where lsort -integer cannot be used (Tcl 8.5 on 64-bit Windows: 32-bit long)
check "wideCmp orders 64-bit neighbours" [lsort -command ::mkitsql::wideCmp {9223372036854775807 9223372036854775806 -9223372036854775808 0 9223372036854775805}] {-9223372036854775808 0 9223372036854775805 9223372036854775806 9223372036854775807}
# the parse cache must not outlive a setting that changes what a text means
set ::mkitsql::ignoreConstraints 0
check "constraints refused" [string match "*PRIMARY KEY is not supported*" [err "CREATE TABLE pk1 (id INT PRIMARY KEY)"]] 1
set ::mkitsql::ignoreConstraints 1
check "same text with ignoreConstraints 1 is accepted" [err "CREATE TABLE pk1 (id INT PRIMARY KEY)"] ""
set ::mkitsql::ignoreConstraints 0
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "review 2: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
