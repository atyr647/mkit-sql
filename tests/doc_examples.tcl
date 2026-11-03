# Runs the examples from docs/SQL.md so the reference cannot drift from the engine.
#   tclsh tests/doc_examples.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/vendor/store.tcl
source [file join [file dirname $here] mkitsql mkitsql.tcl]
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_docs_[pid].mk
file delete $f
set db [store::createSample $f]
set pass 0 ; set fail 0
proc run {sql {params {}}} { mkitsql::run $sql $::db $params }
proc ok {name sql {want __none__} {params {}}} {
    global pass fail
    if {[catch {run $sql $params} r]} { incr fail ; puts "FAIL $name: $r\n   $sql" ; return }
    if {$want eq "__none__"} { incr pass ; return }
    set got [expr {[dict get $r kind] eq "rowset" ? [lindex [dict get $r rows] 0] : [dict get $r text]}]
    if {[llength $got] == 1 && [dict get $r kind] eq "rowset"} { set got [lindex $got 0] }
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}

# --- Queries / joins / LATERAL
ok join1 "SELECT e.name, d.name FROM employees e JOIN departments d ON d.id = e.dept"
ok join2 "SELECT d.name, COUNT(e.id) FROM departments d LEFT JOIN employees e ON e.dept = d.id GROUP BY d.name"
ok lateral "SELECT d.name, t.name, t.salary FROM departments d CROSS JOIN LATERAL (SELECT name, salary FROM employees e WHERE e.dept = d.id ORDER BY salary DESC LIMIT 2) t"
# --- CTEs
ok cte1 "WITH recent AS (SELECT * FROM orders WHERE id > 1010), c(n) AS (SELECT COUNT(*) FROM recent) SELECT n FROM c" 8
ok cte2 "WITH RECURSIVE nums(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM nums WHERE x < 10) SELECT x FROM nums" 1
# --- Windows
ok win1 "SELECT name, dept, salary, RANK() OVER (PARTITION BY dept ORDER BY salary DESC) AS rank_in_dept, SUM(salary) OVER (PARTITION BY dept ORDER BY id) AS running, AVG(salary) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg FROM employees"
ok win2 "SELECT id, SUM(salary) OVER w FROM employees WINDOW w AS (PARTITION BY dept ORDER BY id)"
ok win3 "SELECT dept, RANK() OVER (ORDER BY SUM(salary) DESC) FROM employees GROUP BY dept"
# --- Dates
ok date1 "SELECT DATE '2026-01-31' + INTERVAL '1' MONTH" 2026-02-28
ok date2 "SELECT TIMESTAMP '2026-03-05 23:30:00' + INTERVAL '45' MINUTE" {2026-03-06 00:15:00}
ok date3 "SELECT DATE '2026-03-05' - DATE '2026-01-01'" {63 days}
ok date4 "SELECT EXTRACT(DAY FROM DATE '2026-03-05' - DATE '2026-01-01')" 63
ok date5 "SELECT CAST(hired AS DATE) + INTERVAL '7' DAY FROM employees"
ok date6 "SELECT INTERVAL '2 hours 30 minutes', INTERVAL '1-2' YEAR TO MONTH, INTERVAL '3 04:05:06' DAY TO SECOND" [list 02:30:00 {1 year 2 mons} {3 days 04:05:06}]
# --- Rounding
ok round1 "SELECT ROUND(2.675, 2), ROUND(2.5)" {2.68 3.0}
ok intdiv "SELECT 7 / 2, '2' < '10'" {3 0}
# --- MERGE
run "CREATE TABLE stock (sku VARCHAR(10), qty INT)"
run "INSERT INTO stock VALUES ('a', 10), ('b', 5)"
run "CREATE TABLE incoming (sku VARCHAR(10), qty INT)"
run "INSERT INTO incoming VALUES ('a', 5), ('b', 0), ('c', 9)"
ok merge "MERGE INTO stock s USING incoming i ON s.sku = i.sku WHEN MATCHED AND i.qty = 0 THEN DELETE WHEN MATCHED THEN UPDATE SET qty = s.qty + i.qty WHEN NOT MATCHED THEN INSERT (sku, qty) VALUES (i.sku, i.qty)" "MERGE into 'stock': 1 updated, 1 deleted, 1 inserted."
# --- DDL
ok ddl1 "CREATE TABLE people (id INT, name TEXT, pets TABLE (pet TEXT, age INT))"
ok ins1 "INSERT INTO people (id, name) VALUES (1, 'Ann'), (2, 'Bob')"
ok sub1 "INSERT INTO people\[0\].pets (pet, age) VALUES ('Rex', 3), ('Tom', 1)"
ok sub2 "SELECT * FROM people" [list 1 Ann "[format %c 9656] 2 rows"]
ok sub3 "SELECT name FROM people WHERE pets > 1" Ann
ok sub4 "SELECT p.name, x.pet FROM people p JOIN p.pets x ON x.age > 2" {Ann Rex}
ok sub5 "SELECT * FROM people\[0\].pets ORDER BY age DESC" {Rex 3}
ok ddl2 "ALTER TABLE people ADD COLUMN age INT"
ok ddl3 "ALTER TABLE people RENAME COLUMN age TO years"
ok ddl4 "CREATE TABLE snap AS SELECT id, name FROM people"
ok ddl5 "DROP TABLE IF EXISTS snap"
ok intro1 "SELECT table_name FROM information_schema.tables ORDER BY table_name" departments
ok intro2 "SHOW TABLES"
ok intro3 "DESCRIBE people"
# --- Parameters
ok param1 "SELECT * FROM employees WHERE dept = ? AND salary > ?" __none__ {3 50000}
ok param2 "SELECT * FROM employees WHERE name = :n" __none__ {n Ada}
if {[dict get [mkitsql::query {SELECT name FROM employees WHERE name = :n} $db {n {Ada Lovelace}}] rows] ne {{{Ada Lovelace}}}} { incr fail ; puts "FAIL param named query" } else { incr pass }

store::closeFile $db ; file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
