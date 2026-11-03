# mkit-sql test suite.   Run:   tclsh tests/run.tcl [pattern]
#
# Runs against tests/vendor/mock_mk4tcl.tcl, a pure-Tcl stand-in for Mk4tcl
# (taken from MK Studio).  See README.md: this has NOT yet been run against the
# real Mk4tcl library.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
source $here/mk4load.tcl
puts "(Tcl [info patchlevel], $::mk4kind)"
source $here/vendor/store.tcl
source $root/mkitsql/mkitsql.tcl

set pattern [expr {$argc ? [lindex $argv 0] : "*"}]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail pattern
    if {![string match $pattern $name]} return
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
proc lmap_ {l spec} { lassign $spec v b ; set o {} ; foreach item $l { lappend o [apply [list $v $b] $item] } ; return $o }
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f [file join $tmp mkitsql_test_[pid].mk]
file delete $f
set db [store::createSample $f]

proc q {sql args} { mkitsql::run $sql $::db {*}$args }
proc rows {sql args} { dict get [q $sql {*}$args] rows }
proc col0 {sql} { set r {} ; foreach x [rows $sql] { lappend r [lindex $x 0] } ; return $r }
proc one {sql} { lindex [rows $sql] 0 0 }
proc errmsg {sql args} { if {[catch {q $sql {*}$args} m]} { return $m } ; return "(no error)" }
proc ok {sql} { if {[catch {q $sql} m]} { return "ERROR: $m" } ; return ok }

# ============================================================================
#  Expressions, types and NULL
# ============================================================================
check arith1   [one "SELECT 1 + 2 * 3"] 7
check arith2   [one "SELECT (1 + 2) * 3"] 9
check intdiv   [one "SELECT 7 / 2"] 3
check intdiv2  [one "SELECT -7 / 2"] -3
check realdiv  [one "SELECT 7 / 2.0"] 3.5
check mod1     [one "SELECT 7 % 3"] 1
check mod2     [one "SELECT -7 % 3"] -1
check unary    [one "SELECT -(2 + 3), +4"] -5
check concat   [one "SELECT 'ab' || 'cd' || 'ef'"] abcdef
check concatn  [one "SELECT 'ab' || NULL"] NULL
check nullarith [one "SELECT NULL + 1"] NULL
check nulleq   [one "SELECT NULL = NULL"] NULL
check isnull   [rows "SELECT NULL IS NULL, 1 IS NULL, 1 IS NOT NULL"] {{1 0 1}}
check isdist   [rows "SELECT NULL IS DISTINCT FROM NULL, NULL IS DISTINCT FROM 1, 1 IS NOT DISTINCT FROM 1"] {{0 1 1}}
check istrue   [rows "SELECT 1 IS TRUE, 0 IS TRUE, 0 IS FALSE, NULL IS NOT TRUE"] {{1 0 1 1}}
# three-valued logic
check and3 [rows "SELECT CASE WHEN (NULL AND 0) = 0 THEN 'F' ELSE 'x' END, CASE WHEN (NULL AND 1) IS NULL THEN 'N' ELSE 'x' END, CASE WHEN (1 AND 1) THEN 'T' ELSE 'x' END"] {{F N T}}
check or3  [rows "SELECT CASE WHEN (NULL OR 1) = 1 THEN 'T' ELSE 'x' END, CASE WHEN (NULL OR 0) IS NULL THEN 'N' ELSE 'x' END"] {{T N}}
check not3 [rows "SELECT NOT NULL IS NULL, NOT 1 = 2"] {{0 1}}
check shortcircuit [rows "SELECT CASE WHEN 1 = 0 AND 1 / 0 > 1 THEN 'a' ELSE 'b' END"] {b}
check case1 [rows "SELECT CASE 2 WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'many' END"] {two}
check case2 [rows "SELECT CASE WHEN 1 > 2 THEN 'a' END"] {NULL}
check caselazy [rows "SELECT CASE WHEN 0 = 0 THEN 'ok' ELSE 1 / 0 END"] {ok}
check coalesce [rows "SELECT COALESCE(NULL, NULL, 3), COALESCE(NULL, 'x')"] {{3 x}}
check nullif   [rows "SELECT NULLIF(1, 1), NULLIF(1, 2), NULLIF('a', 'a')"] {{NULL 1 NULL}}
check ifnull   [rows "SELECT IFNULL(NULL, 5)"] 5
check greatest [rows "SELECT GREATEST(1, 5, 3), LEAST(4, 2, 9), GREATEST(1, NULL, 3)"] {{5 2 3}}
# comparison follows the static type
check cmp_text [rows "SELECT '2' < '10', 2 < 10"] {{0 1}}
check cmp_mixed [rows "SELECT '2' < 10, 'abc' = 0"] {{1 0}}
check cmp_str  [rows "SELECT 'a' < 'b', 'B' < 'a', 'abc' = 'abc'"] {{1 1 1}}
check between  [rows "SELECT 5 BETWEEN 1 AND 10, 5 NOT BETWEEN 1 AND 10, 11 BETWEEN 1 AND 10"] {{1 0 0}}
check in1      [rows "SELECT 2 IN (1, 2, 3), 5 IN (1, 2, 3), 5 NOT IN (1, 2, 3)"] {{1 0 1}}
check in_null  [rows "SELECT 5 IN (1, NULL), 1 IN (1, NULL), 5 NOT IN (1, NULL)"] {{NULL 1 NULL}}
check in_text  [rows "SELECT 'b' IN ('a', 'b'), 'z' IN ('a', 'b')"] {{1 0}}
check in_expr  [rows "SELECT 4 IN (1 + 1, 2 + 2)"] {1}
# LIKE
check like1 [rows "SELECT 'hello' LIKE 'h%', 'hello' LIKE 'H%', 'hello' ILIKE 'H%', 'hello' LIKE 'h_llo', 'hello' LIKE '%ll%'"] {{1 0 1 1 1}}
check like2 [rows "SELECT 'a%b' LIKE 'a\\%b' ESCAPE '\\', 'axb' LIKE 'a\\%b' ESCAPE '\\', 'a.b' LIKE 'a.b', 'axb' LIKE 'a.b'"] {{1 0 1 0}}
check like3 [rows "SELECT 'x' NOT LIKE 'y', NULL LIKE 'a'"] {{1 NULL}}
# functions
check fn_str [rows "SELECT UPPER('abc'), LOWER('XyZ'), LENGTH('hello'), SUBSTR('abcdef', 2, 3), SUBSTRING('abcdef' FROM 3), SUBSTRING('abcdef' FROM 2 FOR 2)"] {{ABC xyz 5 bcd cdef bc}}
check fn_trim [rows "SELECT TRIM('  x  '), TRIM(LEADING 'x' FROM 'xxaxx'), TRIM(TRAILING 'x' FROM 'xxaxx'), TRIM(BOTH 'x' FROM 'xxaxx'), LTRIM('  a'), RTRIM('a  ')"] {{x axx xxa a a a}}
check fn_misc [rows "SELECT REPLACE('aXbX', 'X', '-'), POSITION('b' IN 'abc'), LEFT('abcdef', 2), RIGHT('abcdef', 2), REPEAT('ab', 3), REVERSE('abc'), LPAD('7', 3, '0'), RPAD('7', 3, '*')"] {{a-b- 2 ab ef ababab cba 007 7**}}
check fn_num [rows "SELECT ABS(-4), SIGN(-9), CEIL(2.1), FLOOR(2.9), ROUND(3.14159, 2), POWER(2, 10), SQRT(16), MOD(10, 3)"] {{4 -1 3.0 2.0 3.14 1024.0 4.0 1}}
check fn_round [rows "SELECT ROUND(2.5), ROUND(-2.5), ROUND(1234.5678, -2), TRUNC(2.99), TRUNC(-2.99)"] {{3.0 -3.0 1200.0 2.0 -2.0}}
check round_ties [rows "SELECT ROUND(1.625, 2), ROUND(2.675, 2), ROUND(-1.625, 2), ROUND(0.5), ROUND(1.5), ROUND(2.5), ROUND(-0.5), ROUND(1.005, 2), ROUND(0.285, 2)"] {{1.63 2.68 -1.63 1.0 2.0 3.0 -1.0 1.01 0.29}}
check round_neg [rows "SELECT ROUND(15, -1), ROUND(25, -1), ROUND(-25, -1), ROUND(1234, -2), ROUND(1e20, 2), ROUND(0.000123, 5)"] {{20.0 30.0 -30.0 1200.0 1e+20 0.00012}}
check round_real [rows "SELECT ROUND(3) / 5, ROUND(7) / 2"] {{0.6 3.5}}
check trunc_dec [rows "SELECT TRUNC(2.999, 2), TRUNC(-2.999, 2), TRUNC(1234.5, -2)"] {{2.99 -2.99 1200.0}}
check ceil_floor [rows "SELECT CEIL(2.1), FLOOR(2.9), CEIL(-2.1), FLOOR(-2.1), CEIL(5)"] {{3.0 2.0 -2.0 -3.0 5.0}}
check fn_concat [rows "SELECT CONCAT('a', NULL, 'b'), CONCAT_WS('-', 'a', NULL, 'b')"] {{ab a-b}}
check fn_null  [rows "SELECT UPPER(NULL), LENGTH(NULL), ABS(NULL)"] {{NULL NULL NULL}}
check fn_date  [rows "SELECT EXTRACT(YEAR FROM '2026-03-05'), EXTRACT(MONTH FROM '2026-03-05'), EXTRACT(DAY FROM '2026-03-05'), EXTRACT(HOUR FROM '2026-03-05 14:30:00')"] {{2026 3 5 14}}
check fn_cd [string length [one "SELECT CURRENT_DATE"]] 10
# CAST
check cast1 [rows "SELECT CAST('42' AS INT), CAST(3.7 AS INT), CAST(42 AS VARCHAR), CAST('3.5' AS DOUBLE PRECISION), CAST(5 AS DOUBLE)"] {{42 4 42 3.5 5.0}}
check cast2 [rows "SELECT CAST('2026-3-5' AS DATE), CAST(1 AS BOOLEAN), CAST('false' AS BOOLEAN), CAST(NULL AS INT)"] {{2026-03-05 1 0 NULL}}
check cast_err [errmsg "SELECT CAST('abc' AS INT)"] {Invalid number: 'abc'}
check divzero [errmsg "SELECT 1 / 0"] {Division by zero}
check divzero2 [errmsg "SELECT 1.5 / 0"] {Division by zero}
check blob [rows "SELECT LENGTH(X'CAFE')"] {2}
check bigint [one "SELECT 9223372036854775807 + 0"] 9223372036854775807
check realnum [rows "SELECT 1.5e3, .5"] {{1500.0 0.5}}
check colname [dict get [q "SELECT 1 + 2, UPPER('x') AS u, 3 three"] cols] {{1 + 2} u three}

# ============================================================================
#  SELECT on tables
# ============================================================================
check count   [one "SELECT COUNT(*) FROM employees"] 20
check where   [col0 "SELECT name FROM employees WHERE id <= 3 ORDER BY id"] {{Ada Lovelace} {Grace Hopper} {Alan Turing}}
set emp [store::rows $db.employees {id name salary dept} 0 100]
set best -1 ; set bestSal -1
foreach r $emp { if {[lindex $r 2] > $bestSal} { set bestSal [lindex $r 2] ; set best [lindex $r 0] } }
check orderdesc [one "SELECT id FROM employees ORDER BY salary DESC, id LIMIT 1"] $best
check limit1  [col0 "SELECT id FROM employees ORDER BY id LIMIT 2 OFFSET 3"] {4 5}
check fetch   [col0 "SELECT id FROM employees ORDER BY id OFFSET 3 ROWS FETCH FIRST 2 ROWS ONLY"] {4 5}
check fetch2  [col0 "SELECT id FROM employees ORDER BY id FETCH NEXT 1 ROW ONLY"] {1}
check offset0 [llength [rows "SELECT id FROM employees OFFSET 18"]] 2
check like_db [col0 "SELECT id FROM employees WHERE name LIKE 'G%' ORDER BY id"] {2 15}
check ilike_db [col0 "SELECT id FROM employees WHERE name ILIKE 'g%' ORDER BY id"] {2 15}
check in_db   [col0 "SELECT id FROM employees WHERE id IN (2, 4, 99) ORDER BY id"] {2 4}
check between_db [col0 "SELECT id FROM employees WHERE id BETWEEN 3 AND 5"] {3 4 5}
check caseinsens [col0 "SELECT id FROM EMPLOYEES WHERE NAME = 'Alan Turing'"] {3}
check alias   [rows "SELECT e.name FROM employees e WHERE e.id = 1"] {{{Ada Lovelace}}}
check alias_as [rows "SELECT e.name AS n FROM employees AS e WHERE e.id = 1"] {{{Ada Lovelace}}}
check dbqual  [one "SELECT COUNT(*) FROM $db.employees"] 20
check star_q  [dict get [q "SELECT e.* FROM employees e WHERE id = 1"] cols] {id name dept title salary hired active skills}
check bool_col [col0 "SELECT id FROM employees WHERE active ORDER BY id LIMIT 3"] {1 2 3}
check rowid   [col0 "SELECT _rowid FROM employees WHERE id = 5"] {4}
check noFrom_where [rows "SELECT 1 WHERE 1 = 2"] {}
check orderexpr [col0 "SELECT id FROM employees ORDER BY -id LIMIT 2"] {20 19}
check orderalias [col0 "SELECT id AS x FROM employees ORDER BY x DESC LIMIT 2"] {20 19}
check orderord [rows "SELECT id, name FROM employees ORDER BY 1 DESC LIMIT 1"] {{20 {Anita Borg}}}
check ordertext [col0 "SELECT name FROM employees ORDER BY name LIMIT 2"] {{Ada Lovelace} {Alan Turing}}
set pairs [lmap_ $emp {r {list [lindex $r 3] [lindex $r 0]}}]
set sorted [lsort -integer -decreasing -index 0 [lsort -integer -increasing -index 1 $pairs]]
check ordermulti [rows "SELECT dept, id FROM employees ORDER BY dept DESC, id ASC LIMIT 3"] [lrange $sorted 0 2]
check distinct [col0 "SELECT DISTINCT status FROM orders ORDER BY status"] {new paid returned shipped}
check distinct2 [llength [rows "SELECT DISTINCT dept FROM employees"]] 5

# ---- aggregates --------------------------------------------------------------
check agg1  [rows "SELECT COUNT(*), MIN(id), MAX(id), SUM(id) FROM employees"] {{20 1 20 210}}
check agg2  [rows "SELECT AVG(id) FROM employees"] {10.5}
check agg_empty [rows "SELECT COUNT(*), SUM(id), MIN(id), AVG(id) FROM employees WHERE id > 1000"] {{0 NULL NULL NULL}}
check agg_cd [rows "SELECT COUNT(DISTINCT dept), COUNT(dept), COUNT(*) FROM employees"] {{5 20 20}}
check agg_sumd [rows "SELECT SUM(DISTINCT dept) FROM employees"] {15}
check agg_text [rows "SELECT MIN(name), MAX(name) FROM employees"] {{{Ada Lovelace} {Tim Berners-Lee}}}
check agg_real [rows "SELECT SUM(price) FROM products WHERE sku IN ('MK-001', 'MK-002')"] {101.5}
check agg_str [rows "SELECT STRING_AGG(name, ', ') FROM (SELECT name FROM employees ORDER BY id LIMIT 3) t"] {{{Ada Lovelace, Grace Hopper, Alan Turing}}}
check group1 [rows "SELECT dept, COUNT(*) AS n FROM employees GROUP BY dept ORDER BY dept"] {{1 4} {2 4} {3 4} {4 4} {5 4}}
check group_ord [rows "SELECT dept, COUNT(*) FROM employees GROUP BY 1 ORDER BY 1 DESC LIMIT 1"] {{5 4}}
check group_alias [llength [rows "SELECT dept AS d, COUNT(*) FROM employees GROUP BY d"]] 5
check group_expr [rows "SELECT dept % 2, COUNT(*) FROM employees GROUP BY dept % 2 ORDER BY 1"] {{0 8} {1 12}}
check having  [llength [rows "SELECT dept, COUNT(*) c FROM employees GROUP BY dept HAVING COUNT(*) > 100"]] 0
check having2 [rows "SELECT dept FROM employees GROUP BY dept HAVING SUM(salary) > 100000 ORDER BY dept"] [
    set tot [dict create] ; foreach r $emp { set d [lindex $r 3] ; dict set tot $d [expr {[dict exists $tot $d] ? [dict get $tot $d] + [lindex $r 2] : [lindex $r 2]}] }
    set res {} ; foreach d [lsort -integer [dict keys $tot]] { if {[dict get $tot $d] > 100000} { lappend res [list $d] } } ; set res]
check order_agg [one "SELECT dept FROM employees GROUP BY dept ORDER BY SUM(salary) DESC LIMIT 1"] [
    set bd 0 ; set bs -1 ; foreach d [dict keys $tot] { if {[dict get $tot $d] > $bs} { set bs [dict get $tot $d] ; set bd $d } } ; set bd]
check agg_expr [rows "SELECT dept, MAX(salary) - MIN(salary) FROM employees WHERE dept = 1 GROUP BY dept"] [
    set s {} ; foreach r $emp { if {[lindex $r 3] == 1} { lappend s [lindex $r 2] } } ; list [list 1 [expr {[tcl::mathfunc::max {*}$s] - [tcl::mathfunc::min {*}$s]}]]]
check having_noGroup [rows "SELECT COUNT(*) FROM employees HAVING COUNT(*) > 5"] {20}
check agg_group_err [errmsg "SELECT name, COUNT(*) FROM employees GROUP BY dept"] {Column 'name' must appear in the GROUP BY clause or be used in an aggregate function}
check agg_where_err [errmsg "SELECT * FROM employees WHERE COUNT(*) > 1"] {Aggregate functions are not allowed in WHERE; use HAVING}
check agg_nest_err [errmsg "SELECT SUM(COUNT(*)) FROM employees"] {Aggregate function calls cannot be nested}

# ============================================================================
#  Joins
# ============================================================================
set nEmp 0 ; foreach r $emp { incr nEmp }
check join_inner [llength [rows "SELECT e.id FROM employees e JOIN departments d ON e.dept = d.id"]] 20
check join_where [col0 "SELECT e.name FROM employees e JOIN departments d ON e.dept = d.id WHERE d.name = 'Design' ORDER BY e.id"] {{Alan Turing} {Margaret Hamilton} {Tim Berners-Lee} {Sophie Wilson}}
check join_comma [llength [rows "SELECT e.id FROM employees e, departments d WHERE e.dept = d.id"]] 20
check join_cross [llength [rows "SELECT * FROM departments CROSS JOIN products"]] 40
check join_cross2 [llength [rows "SELECT 1 FROM departments, products"]] 40
check join_using [dict get [q "SELECT * FROM departments d JOIN employees e USING (id)"] cols] {id name location budget name dept title salary hired active skills}
check join_natural [llength [rows "SELECT * FROM departments NATURAL JOIN employees"]] [llength [rows "SELECT * FROM departments d JOIN employees e USING (id, name)"]]
check join_self [llength [rows "SELECT a.id FROM employees a JOIN employees b ON a.dept = b.dept AND a.id < b.id"]] 30
check join_left [rows "SELECT d.name, COUNT(e.id) FROM departments d LEFT JOIN employees e ON e.dept = d.id AND e.salary > 1000000 GROUP BY d.name ORDER BY d.name"] {{Design 0} {Engineering 0} {Research 0} {Sales 0} {Support 0}}
check join_left_null [rows "SELECT d.name, e.id FROM departments d LEFT JOIN employees e ON e.id = d.id + 100 WHERE d.id = 1"] {{Engineering NULL}}
check join_left_where [llength [rows "SELECT d.id FROM departments d LEFT JOIN employees e ON e.id = d.id + 100 WHERE e.id IS NULL"]] 5
check join_right [llength [rows "SELECT d.id, e.id FROM employees e RIGHT JOIN departments d ON e.id = d.id + 18"]] 5
check join_full [llength [rows "SELECT d.id, e.id FROM departments d FULL JOIN employees e ON e.id = d.id"]] 20
check join_3way [llength [rows "SELECT o.id FROM orders o JOIN products p ON p.sku = o.status JOIN departments d ON d.id = 1"]] 0
check join_nonequi [llength [rows "SELECT a.id FROM departments a JOIN departments b ON a.id < b.id"]] 10
check join_alias_req [errmsg "SELECT * FROM employees JOIN employees ON 1 = 1"] {Table name 'employees' is used more than once in FROM.  Give one an alias.}
check join_ambig [string match "Column reference 'id' is ambiguous*" [errmsg "SELECT id FROM employees e JOIN departments d ON e.dept = d.id"]] 1
check join_hash_eq_nested [llength [rows "SELECT e.id FROM employees e JOIN departments d ON e.dept = d.id + 0"]] 20
check join_on_expr [llength [rows "SELECT e.id FROM employees e JOIN departments d ON e.dept = d.id AND d.budget > 1000000"]] [
    set n 0 ; foreach r $emp { if {[lindex $r 3] in {1 5}} { incr n } } ; set n]
check join_mixed_types [llength [rows "SELECT 1 FROM departments d JOIN products p ON d.budget = p.price"]] 0

# ============================================================================
#  Subqueries, CTEs, derived tables, set operations
# ============================================================================
check sub_scalar [rows "SELECT (SELECT MAX(id) FROM employees)"] {20}
check sub_scalar_where [col0 "SELECT id FROM employees WHERE salary = (SELECT MAX(salary) FROM employees)"] [list $best]
check sub_in [col0 "SELECT id FROM departments WHERE id IN (SELECT dept FROM employees WHERE id < 3) ORDER BY id"] {3 5}
check sub_notin [col0 "SELECT id FROM departments WHERE id NOT IN (SELECT dept FROM employees WHERE id < 3) ORDER BY id"] {1 2 4}
check sub_notin_null [rows "SELECT 1 WHERE 5 NOT IN (SELECT NULL)"] {}
check sub_exists [col0 "SELECT id FROM departments d WHERE EXISTS (SELECT 1 FROM employees e WHERE e.dept = d.id AND e.id = 1)"] {3}
check sub_notexists [col0 "SELECT id FROM departments d WHERE NOT EXISTS (SELECT 1 FROM employees e WHERE e.dept = d.id AND e.id < 3) ORDER BY id"] {1 2 4}
check sub_corr [rows "SELECT e.id, (SELECT d.name FROM departments d WHERE d.id = e.dept) FROM employees e WHERE e.id <= 2"] {{1 Sales} {2 Research}}
check sub_corr_agg [rows "SELECT d.name, (SELECT COUNT(*) FROM employees e WHERE e.dept = d.id) FROM departments d ORDER BY d.id"] {{Engineering 4} {Design 4} {Sales 4} {Support 4} {Research 4}}
check sub_corr_nested [rows "SELECT d.id FROM departments d WHERE EXISTS (SELECT 1 FROM employees e WHERE e.dept = d.id AND EXISTS (SELECT 1 FROM employees x WHERE x.dept = d.id AND x.id = 1)) ORDER BY d.id"] {3}
# correlated lookups (hash-indexed): same results as a per-row scan
check lk_extra [col0 "SELECT d.id FROM departments d WHERE EXISTS (SELECT 1 FROM employees e WHERE e.dept = d.id AND e.id > 15) ORDER BY d.id"] [
    set ds {} ; foreach r $emp { if {[lindex $r 0] > 15} { lappend ds [lindex $r 3] } } ; lsort -integer -unique $ds]
check lk_outer_expr [col0 "SELECT d.id FROM departments d WHERE EXISTS (SELECT 1 FROM employees e WHERE e.dept + 1 = d.id + 1 AND e.id = 3)"] {2}
check lk_outer_expr2 [col0 "SELECT d.id FROM departments d WHERE (SELECT COUNT(*) FROM employees e WHERE e.dept = d.id * 1) = 4 ORDER BY d.id"] {1 2 3 4 5}
check lk_mixed [col0 "SELECT d.id FROM departments d WHERE EXISTS (SELECT 1 FROM employees e WHERE e.dept = d.id + 0.0 AND e.id = 3)"] {2}
check lk_text [col0 "SELECT d.id FROM departments d WHERE EXISTS (SELECT 1 FROM departments x WHERE x.name = d.name AND x.id = d.id) ORDER BY d.id"] {1 2 3 4 5}
check lk_null [rows "SELECT d.id FROM departments d WHERE EXISTS (SELECT 1 FROM employees e WHERE e.dept = NULLIF(d.id, d.id))"] {}
check lk_two_keys [llength [rows "SELECT a.id FROM departments a WHERE EXISTS (SELECT 1 FROM departments b WHERE b.id = a.id AND b.name = a.name)"]] 5
check lk_in [col0 "SELECT e.id FROM employees e WHERE e.dept IN (SELECT d.id FROM departments d WHERE d.id = e.dept AND d.location = 'Berlin') ORDER BY e.id"] [
    set o {} ; foreach r $emp { if {[lindex $r 3] == 1} { lappend o [lindex $r 0] } } ; lsort -integer $o]
check sub_toomany [errmsg "SELECT (SELECT id FROM employees)"] {More than one row returned by a subquery used as an expression}
check sub_empty [rows "SELECT (SELECT id FROM employees WHERE id = 99)"] {NULL}
check sub_cols_err [errmsg "SELECT (SELECT id, name FROM employees LIMIT 1)"] {A scalar subquery must return exactly one column}
check derived [rows "SELECT t.n FROM (SELECT COUNT(*) AS n FROM employees) t"] {20}
check derived_cols [rows "SELECT a, b FROM (SELECT id, name FROM employees WHERE id = 1) AS t(a, b)"] {{1 {Ada Lovelace}}}
check derived_join [llength [rows "SELECT t.dept, d.name FROM (SELECT DISTINCT dept FROM employees) t JOIN departments d ON d.id = t.dept"]] 5
check derived_noalias [string match "Expected a alias*" [errmsg "SELECT * FROM (SELECT 1)"]] 1
check cte1 [rows "WITH t AS (SELECT dept, COUNT(*) AS c FROM employees GROUP BY dept) SELECT COUNT(*) FROM t WHERE c = 4"] {5}
check cte2 [rows "WITH a AS (SELECT 1 AS x), b AS (SELECT x + 1 AS y FROM a) SELECT y FROM b"] {2}
check cte_cols [rows "WITH t(p, q) AS (SELECT 1, 2) SELECT q, p FROM t"] {{2 1}}
check cte_twice [rows "WITH t AS (SELECT 3 AS v) SELECT a.v + b.v FROM t a, t b"] {6}
check values1 [rows "VALUES (1, 'a'), (2, 'b')"] {{1 a} {2 b}}
check values2 [rows "SELECT n, s FROM (VALUES (1, 'a'), (2, 'b')) AS v(n, s) WHERE n > 1"] {{2 b}}
check union1 [col0 "SELECT dept FROM employees UNION SELECT id FROM departments ORDER BY 1"] {1 2 3 4 5}
check union_all [llength [rows "SELECT dept FROM employees UNION ALL SELECT id FROM departments"]] 25
check intersect [col0 "SELECT id FROM departments INTERSECT SELECT id FROM employees WHERE id < 3 ORDER BY 1"] {1 2}
check except [col0 "SELECT id FROM departments EXCEPT SELECT id FROM employees WHERE id < 3 ORDER BY 1"] {3 4 5}
check union_limit [rows "SELECT 1 UNION SELECT 2 UNION SELECT 3 ORDER BY 1 DESC LIMIT 2"] {3 2}
check union_prec [col0 "SELECT 1 UNION SELECT 2 INTERSECT SELECT 2 ORDER BY 1"] {1 2}
check union_cols_err [errmsg "SELECT 1 UNION SELECT 1, 2"] {Each UNION query must have the same number of columns (1 vs 2)}
check union_null [rows "SELECT NULL UNION SELECT NULL"] {NULL}
check paren_query [rows "(SELECT 1) UNION (SELECT 2) ORDER BY 1"] {1 2}

# ============================================================================
#  Text that merely LOOKS like a number must come back untouched
#  (Tcl's expr rewrites "007" -> 7 and "1e3" -> 1000.0; the engine must never do that)
# ============================================================================
q "CREATE TABLE codes (id INT, code VARCHAR(20), grp VARCHAR(20))"
foreach {i c g} {1 007 1e3 2 1e3 007 3 0x10 007 4 { 5 } 1e3 5 +5 007 6 abc 007 7 00 1e3} {
    q "INSERT INTO codes VALUES ($i, '$c', '$g')"
}
set raw [list 007 1e3 0x10 { 5 } +5 abc 00]
check lit_text   [col0 "SELECT code FROM codes ORDER BY id"] $raw
check lit_group  [lsort [col0 "SELECT grp FROM codes GROUP BY grp"]] [lsort {1e3 007}]
check lit_group2 [lsort [col0 "SELECT code FROM codes GROUP BY code"]] [lsort $raw]
check lit_distinct [lsort [col0 "SELECT DISTINCT code FROM codes"]] [lsort $raw]
check lit_order  [col0 "SELECT code FROM codes ORDER BY code"] [lsort -ascii $raw]
check lit_orderd [col0 "SELECT code FROM codes ORDER BY code DESC"] [lsort -ascii -decreasing $raw]
check lit_minmax [rows "SELECT MIN(code), MAX(code) FROM codes"] [list [list { 5 } abc]]
check lit_null_row [rows "SELECT code, NULL FROM codes WHERE id = 1"] {{007 NULL}}
check lit_null_row2 [rows "SELECT code, d.id FROM codes c LEFT JOIN departments d ON d.id = c.id + 100 WHERE c.id = 2"] {{1e3 NULL}}
check lit_case  [col0 "SELECT CASE WHEN id = 1 THEN code ELSE grp END FROM codes WHERE id IN (1, 2) ORDER BY id"] {007 007}
check lit_coalesce [col0 "SELECT COALESCE(NULLIF(code, 'zz'), 'q') FROM codes WHERE id = 1"] {007}
check lit_name  [dict get [q "SELECT 1e3, 007 FROM codes LIMIT 1"] cols] {1e3 007}
check lit_in    [col0 "SELECT id FROM codes WHERE code IN ('007', '1e3') ORDER BY id"] {1 2}
check lit_eq    [col0 "SELECT id FROM codes WHERE code = '007'"] {1}
check lit_strcmp [col0 "SELECT id FROM codes WHERE code = '7'"] {}
check lit_union [lsort [col0 "SELECT code FROM codes WHERE id <= 2 UNION SELECT '1e3'"]] [lsort {007 1e3}]
q "DROP TABLE codes"

# ============================================================================
#  Window functions
# ============================================================================
set V "(VALUES (1, 'a'), (2, 'a'), (2, 'b'), (5, 'b'), (7, 'b')) t(x, p)"
check win_rownum  [col0 "SELECT ROW_NUMBER() OVER (ORDER BY x, p) FROM $V ORDER BY 1"] {1 2 3 4 5}
check win_rank    [rows "SELECT x, RANK() OVER (ORDER BY x), DENSE_RANK() OVER (ORDER BY x) FROM $V ORDER BY x, p"] {{1 1 1} {2 2 2} {2 2 2} {5 4 3} {7 5 4}}
check win_running [rows "SELECT x, SUM(x) OVER (ORDER BY x) FROM $V ORDER BY x, p"] {{1 1} {2 5} {2 5} {5 10} {7 17}}
check win_rows    [rows "SELECT x, SUM(x) OVER (ORDER BY x, p ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM $V ORDER BY x, p"] {{1 1} {2 3} {2 4} {5 7} {7 12}}
check win_range   [rows "SELECT x, COUNT(*) OVER (ORDER BY x RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM $V ORDER BY x, p"] {{1 3} {2 3} {2 3} {5 1} {7 1}}
check win_groups  [rows "SELECT x, SUM(x) OVER (ORDER BY x GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM $V ORDER BY x, p"] {{1 1} {2 5} {2 5} {5 9} {7 12}}
check win_part    [rows "SELECT p, x, SUM(x) OVER (PARTITION BY p) FROM $V ORDER BY p, x"] {{a 1 3} {a 2 3} {b 2 14} {b 5 14} {b 7 14}}
check win_whole   [col0 "SELECT COUNT(*) OVER () FROM $V"] {5 5 5 5 5}
check win_lag     [rows "SELECT x, LAG(x) OVER (ORDER BY x, p), LEAD(x, 2, -1) OVER (ORDER BY x, p) FROM $V ORDER BY x, p"] {{1 NULL 2} {2 1 5} {2 2 7} {5 2 -1} {7 5 -1}}
check win_firstlast [rows "SELECT x, FIRST_VALUE(x) OVER (PARTITION BY p ORDER BY x), LAST_VALUE(x) OVER (PARTITION BY p ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM $V ORDER BY p, x"] {{1 1 2} {2 1 2} {2 2 7} {5 2 7} {7 2 7}}
check win_lastdefault [col0 "SELECT LAST_VALUE(x) OVER (ORDER BY x) FROM $V ORDER BY x, p"] {1 2 2 5 7}
check win_nth     [col0 "SELECT NTH_VALUE(x, 2) OVER (ORDER BY x, p) FROM $V ORDER BY x, p"] {NULL 2 2 2 2}
check win_ntile   [col0 "SELECT NTILE(2) OVER (ORDER BY x, p) FROM $V ORDER BY x, p"] {1 1 1 2 2}
check win_pct     [col0 "SELECT PERCENT_RANK() OVER (ORDER BY x) FROM $V ORDER BY x, p"] {0.0 0.25 0.25 0.75 1.0}
check win_cume    [col0 "SELECT CUME_DIST() OVER (ORDER BY x) FROM $V ORDER BY x, p"] {0.2 0.6 0.6 0.8 1.0}
check win_avg_min [rows "SELECT p, MIN(x) OVER (PARTITION BY p), MAX(x) OVER (PARTITION BY p), AVG(x) OVER (PARTITION BY p) FROM $V WHERE x = 1 OR x = 7 ORDER BY p"] {{a 1 1 1.0} {b 7 7 7.0}}
check win_strmax  [rows "SELECT MAX(p) OVER () FROM $V LIMIT 1"] {b}
check win_named   [rows "SELECT x, SUM(x) OVER w FROM $V WINDOW w AS (ORDER BY x, p) ORDER BY x, p"] {{1 1} {2 3} {2 5} {5 10} {7 17}}
check win_named2  [rows "SELECT x, SUM(x) OVER (w ROWS 1 PRECEDING) FROM $V WINDOW w AS (ORDER BY x, p) ORDER BY x, p"] {{1 1} {2 3} {2 4} {5 7} {7 12}}
check win_expr    [col0 "SELECT SUM(x) OVER (ORDER BY x, p) * 10 FROM $V ORDER BY x, p"] {10 30 50 100 170}
check win_in_order [col0 "SELECT x FROM $V ORDER BY ROW_NUMBER() OVER (ORDER BY x DESC, p)"] {7 5 2 2 1}
check win_distinct [rows "SELECT DISTINCT p, COUNT(*) OVER (PARTITION BY p) FROM $V ORDER BY p"] {{a 2} {b 3}}
check win_group   [rows "SELECT dept, COUNT(*), RANK() OVER (ORDER BY SUM(salary) DESC) FROM employees GROUP BY dept ORDER BY dept"] [
    set tots {} ; foreach r $emp { set d [lindex $r 3] ; dict set tots $d [expr {[dict exists $tots $d] ? [dict get $tots $d] + [lindex $r 2] : [lindex $r 2]}] }
    set res {} ; foreach d [lsort -integer [dict keys $tots]] {
        set rk 1 ; foreach e [dict keys $tots] { if {[dict get $tots $e] > [dict get $tots $d]} { incr rk } }
        lappend res [list $d [dict size [dict create]] $rk] }
    lmap_ $res {r {lindex $r 0}} ; set out {} ; foreach r $res { lappend out [list [lindex $r 0] 4 [lindex $r 2]] } ; set out]
check win_empty   [rows "SELECT ROW_NUMBER() OVER (ORDER BY id) FROM employees WHERE id > 1000"] {}
check win_subq    [col0 "SELECT n FROM (SELECT x, ROW_NUMBER() OVER (ORDER BY x, p) AS n FROM $V) q WHERE n > 3 ORDER BY n"] {4 5}
check win_text_order [col0 "SELECT p || x FROM $V ORDER BY ROW_NUMBER() OVER (ORDER BY p DESC, x DESC)"] {b7 b5 b2 a2 a1}
check win_e_where [errmsg "SELECT x FROM $V WHERE ROW_NUMBER() OVER () = 1"] {Window functions are not allowed in WHERE}
check win_e_nest  [errmsg "SELECT SUM(ROW_NUMBER() OVER ()) OVER () FROM $V"] {Window function calls cannot be nested}
check win_e_name  [string match "Unknown window 'zz'*" [errmsg "SELECT SUM(x) OVER zz FROM $V"]] 1
check win_e_noover [errmsg "SELECT ROW_NUMBER() FROM $V"] {ROW_NUMBER() is a window function and needs an OVER clause}
check win_e_notfn [errmsg "SELECT UPPER(p) OVER () FROM $V"] {UPPER() is not a window function}
check win_e_frame [errmsg "SELECT SUM(x) OVER (ORDER BY x ROWS BETWEEN CURRENT ROW AND 1 PRECEDING) FROM $V"] {Invalid window frame: the start must not come after the end}
check win_e_off   [errmsg "SELECT SUM(x) OVER (ORDER BY x ROWS 1.5 PRECEDING) FROM $V"] {A ROWS / GROUPS frame offset must be a whole number}
check win_e_range [errmsg "SELECT SUM(x) OVER (ORDER BY x, p RANGE 1 PRECEDING) FROM $V"] {A RANGE frame with an offset needs exactly one ORDER BY column}
check win_e_args  [errmsg "SELECT NTILE() OVER () FROM $V"] {Window function NTILE() takes 1 argument, not 0}
check win_e_group [string match "Window functions are not allowed in GROUP BY" [errmsg "SELECT 1 FROM $V GROUP BY ROW_NUMBER() OVER ()"]] 1
check win_e_dist  [string match "*DISTINCT*" [errmsg "SELECT COUNT(DISTINCT x) OVER () FROM $V"]] 1
check win_filter  [rows "SELECT COUNT(*) FILTER (WHERE x > 1), SUM(x) FILTER (WHERE p = 'b'), MAX(x) FILTER (WHERE x < 5) FROM $V"] {{4 14 2}}
check win_filter_g [rows "SELECT p, COUNT(*) FILTER (WHERE x = 2) FROM $V GROUP BY p ORDER BY p"] {{a 1} {b 1}}
check win_filter_w [col0 "SELECT SUM(x) FILTER (WHERE x > 1) OVER (ORDER BY x, p) FROM $V ORDER BY x, p"] {NULL 2 4 9 16}

# ============================================================================
#  WITH RECURSIVE
# ============================================================================
check rec_count  [col0 "WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < 10) SELECT x FROM cnt ORDER BY x"] {1 2 3 4 5 6 7 8 9 10}
check rec_fact   [rows "WITH RECURSIVE f(n, v) AS (SELECT 1, 1 UNION ALL SELECT n + 1, v * (n + 1) FROM f WHERE n < 10) SELECT v FROM f WHERE n = 10"] {3628800}
check rec_union_cycle [col0 "WITH RECURSIVE t(x) AS (SELECT 1 UNION SELECT (x % 3) + 1 FROM t) SELECT x FROM t ORDER BY x"] {1 2 3}
check rec_limit  [col0 "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT x FROM n LIMIT 4"] {1 2 3 4}
check rec_graph  [col0 "WITH RECURSIVE e(a, b) AS (VALUES (1,2),(2,3),(3,1),(3,4),(9,10)), r(n) AS (SELECT 1 UNION SELECT b FROM e JOIN r ON a = n) SELECT n FROM r ORDER BY n"] {1 2 3 4}
check rec_tree   [col0 "WITH RECURSIVE p(id, par, nm) AS (VALUES (1,0,'r'),(2,1,'a'),(3,2,'b')), t(id, path) AS (SELECT id, nm FROM p WHERE par = 0 UNION ALL SELECT p.id, t.path || '/' || p.nm FROM p JOIN t ON p.par = t.id) SELECT path FROM t ORDER BY id"] {r r/a r/a/b}
check rec_table  [col0 "WITH RECURSIVE up(id) AS (SELECT id FROM departments WHERE id = 5 UNION ALL SELECT id - 1 FROM up WHERE id > 1) SELECT id FROM up ORDER BY id"] {1 2 3 4 5}
check rec_reuse  [rows "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3) SELECT (SELECT SUM(x) FROM c), (SELECT COUNT(*) FROM c)"] {{6 3}}
check rec_nonrec [col0 "WITH RECURSIVE x(v) AS (SELECT 1 UNION ALL SELECT 2) SELECT v FROM x ORDER BY v"] {1 2}
check rec_guard  [string match "Recursive query stopped after * rounds*" [errmsg "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x FROM c) SELECT COUNT(*) FROM c"]] 1
set mkitsql::maxRecursion 5
check rec_guard2 [string match "Recursive query stopped after 5 rounds*" [errmsg "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 50) SELECT COUNT(*) FROM c"]] 1
set mkitsql::maxRecursion 100000
check rec_cols  [string match "Each branch of recursive query 'c' must have the same number of columns" [errmsg "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x, x FROM c WHERE x < 3) SELECT * FROM c"]] 1
check rec_names [string match "Recursive query 'c' returns 1 columns but 2 names were given" [errmsg "WITH RECURSIVE c(x, y) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3) SELECT * FROM c"]] 1
check rec_order [string match "ORDER BY / LIMIT inside the definition of recursive query*" [errmsg "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3 ORDER BY 1) SELECT * FROM c"]] 1
check rec_anchor_self [string match "Unknown table 'c'*" [errmsg "WITH RECURSIVE c(x) AS (SELECT x FROM c UNION ALL SELECT 1) SELECT * FROM c"]] 1

# ============================================================================
#  ANY / ALL / SOME and row values
# ============================================================================
check any_gt    [col0 "SELECT id FROM departments WHERE id > ANY (SELECT 2 UNION SELECT 4) ORDER BY id"] {3 4 5}
check any_eq    [col0 "SELECT id FROM departments WHERE id = ANY (SELECT 2 UNION SELECT 4) ORDER BY id"] {2 4}
check some_syn  [col0 "SELECT id FROM departments WHERE id = SOME (SELECT 2 UNION SELECT 4) ORDER BY id"] {2 4}
check all_gt    [col0 "SELECT id FROM departments WHERE id > ALL (SELECT 2 UNION SELECT 4) ORDER BY id"] {5}
check all_ne    [col0 "SELECT id FROM departments WHERE id <> ALL (SELECT 2 UNION SELECT 4) ORDER BY id"] {1 3 5}
check all_empty [col0 "SELECT id FROM departments WHERE id > ALL (SELECT id FROM departments WHERE id > 99) ORDER BY id"] {1 2 3 4 5}
check any_empty [col0 "SELECT id FROM departments WHERE id > ANY (SELECT id FROM departments WHERE id > 99) ORDER BY id"] {}
check any_null  [rows "SELECT 3 = ANY (SELECT 1 UNION SELECT NULL), 1 = ANY (SELECT 1 UNION SELECT NULL), 3 <> ALL (SELECT 1 UNION SELECT NULL), 0 <> ALL (SELECT 1 WHERE 0)"] {{NULL 1 NULL 1}}
check any_corr  [col0 "SELECT d.id FROM departments d WHERE d.id > ALL (SELECT e.dept FROM employees e WHERE e.id <= d.id - 3) ORDER BY d.id"] [col0 "SELECT d.id FROM departments d WHERE NOT EXISTS (SELECT 1 FROM employees e WHERE e.id <= d.id - 3 AND NOT (d.id > e.dept)) ORDER BY d.id"]
check any_text  [col0 "SELECT name FROM departments WHERE name = ANY (SELECT 'Sales' UNION SELECT 'Design') ORDER BY name"] {Design Sales}
check any_cols  [errmsg "SELECT 1 WHERE 1 = ANY (SELECT 1, 2)"] {A subquery used with ANY must return exactly one column}
check row_eq    [col0 "SELECT id FROM departments WHERE (id, name) = (3, 'Sales')"] {3}
check row_ne    [llength [col0 "SELECT id FROM departments WHERE (id, name) <> (3, 'Sales')"]] 4
check row_lt    [col0 "SELECT id FROM departments WHERE (id, name) < (3, 'Sales') ORDER BY id"] {1 2}
check row_le    [col0 "SELECT id FROM departments WHERE (id, name) <= (3, 'Sales') ORDER BY id"] {1 2 3}
check row_gt    [col0 "SELECT id FROM departments WHERE (id, name) > (3, 'Sales') ORDER BY id"] {4 5}
check row_lex   [rows "SELECT (1, 5) < (2, 0), (2, 1) < (2, 0), (2, 0) <= (2, 0), (3, 'a') >= (3, 'b')"] {{1 0 1 0}}
check row_in    [col0 "SELECT id FROM departments WHERE (id, name) IN ((1, 'Engineering'), (4, 'Support'), (5, 'x')) ORDER BY id"] {1 4}
check row_notin [col0 "SELECT id FROM departments WHERE (id, name) NOT IN ((1, 'Engineering'), (4, 'Support')) ORDER BY id"] {2 3 5}
check row_insub [col0 "SELECT id FROM departments WHERE (id, location) IN (SELECT dept, 'Berlin' FROM employees) ORDER BY id"] {1}
check row_insub2 [col0 "SELECT id FROM departments d WHERE (id, 'x') IN (SELECT d.id, 'x' UNION SELECT 99, 'y')"] {1 2 3 4 5}
check row_corr  [col0 "SELECT d.id FROM departments d WHERE (d.id, 1) IN (SELECT e.dept, 1 FROM employees e WHERE e.id = d.id) ORDER BY d.id"] [col0 "SELECT d.id FROM departments d WHERE EXISTS (SELECT 1 FROM employees e WHERE e.id = d.id AND e.dept = d.id) ORDER BY d.id"]
check row_notinsub [col0 "SELECT id FROM departments WHERE (id, 1) NOT IN (SELECT dept, 1 FROM employees WHERE id = 1) ORDER BY id"] {1 2 4 5}
check row_ROW   [col0 "SELECT id FROM departments WHERE ROW(id, name) = ROW(2, 'Design')"] {2}
check row_size  [string match "Row values have different sizes*" [errmsg "SELECT 1 WHERE (1, 2) = (1, 2, 3)"]] 1
check row_mixed [string match "A row value (a, b) can only be compared*" [errmsg "SELECT 1 WHERE (1, 2) = 1"]] 1
check row_bare  [errmsg "SELECT (1, 2)"] {A row value (a, b) can only be used in a comparison or with IN}

# ============================================================================
#  Dates, times and intervals
# ============================================================================
check dt_lit     [rows "SELECT DATE '2026-03-05', TIMESTAMP '2026-3-5 14:30:00', TIME '9:05'"] [list [list 2026-03-05 {2026-03-05 14:30:00} 09:05:00]]
check dt_addday  [one "SELECT DATE '2026-03-05' + INTERVAL '10' DAY"] 2026-03-15
check dt_clamp   [rows "SELECT DATE '2026-01-31' + INTERVAL '1' MONTH, DATE '2024-02-29' + INTERVAL '1' YEAR, DATE '2026-03-31' - INTERVAL '1' MONTH"] {{2026-02-28 2025-02-28 2026-02-28}}
check dt_leap    [rows "SELECT DATE '2024-02-28' + INTERVAL '1' DAY, DATE '2026-02-28' + INTERVAL '1' DAY, DATE '2026-12-31' + INTERVAL '1' DAY"] {{2024-02-29 2026-03-01 2027-01-01}}
check dt_ts      [one "SELECT TIMESTAMP '2026-03-05 23:30:00' + INTERVAL '45' MINUTE"] {2026-03-06 00:15:00}
check dt_ts_sub  [one "SELECT TIMESTAMP '2026-03-01 00:10:00' - INTERVAL '20' MINUTE"] {2026-02-28 23:50:00}
check dt_time    [one "SELECT TIME '23:30:00' + INTERVAL '45' MINUTE"] 00:15:00
check dt_commut  [one "SELECT INTERVAL '2' DAY + DATE '2026-03-05'"] 2026-03-07
check dt_hours_on_date [one "SELECT DATE '2026-03-05' + INTERVAL '36' HOUR"] {2026-03-06 12:00:00}
check dt_diff    [rows "SELECT DATE '2026-03-05' - DATE '2026-01-01', TIMESTAMP '2026-03-05 12:00:00' - TIMESTAMP '2026-03-05 10:30:15'"] {{{63 days} 01:29:45}}
check dt_diff_neg [one "SELECT DATE '2026-01-01' - DATE '2026-03-05'"] {-63 days}
check dt_extract_diff [one "SELECT EXTRACT(DAY FROM DATE '2026-03-05' - DATE '2026-01-01')"] 63
check iv_lits    [rows "SELECT INTERVAL '1-2' YEAR TO MONTH, INTERVAL '3 04:05:06' DAY TO SECOND, INTERVAL '90' MINUTE, INTERVAL '1 year 2 mons 3 days', INTERVAL '5' SECOND"] [list [list {1 year 2 mons} {3 days 04:05:06} 01:30:00 {1 year 2 mons 3 days} 00:00:05]]
check iv_more    [rows "SELECT INTERVAL '2 weeks', INTERVAL '1.5' HOUR, INTERVAL '1 02:30' DAY TO MINUTE, INTERVAL '2:30' HOUR TO MINUTE, INTERVAL '-3' DAY"] [list [list {14 days} 01:30:00 {1 day 02:30:00} 02:30:00 {-3 days}]]
check iv_pg      [rows "SELECT INTERVAL '2 hours 30 minutes', INTERVAL '3 days', INTERVAL '-5 hours', INTERVAL '1 day 02:03:04'"] [list [list 02:30:00 {3 days} -05:00:00 {1 day 02:03:04}]]
check iv_extract [rows "SELECT EXTRACT(YEAR FROM INTERVAL '14' MONTH), EXTRACT(MONTH FROM INTERVAL '14' MONTH), EXTRACT(DAY FROM INTERVAL '3 04:05:06' DAY TO SECOND), EXTRACT(HOUR FROM INTERVAL '3 04:05:06' DAY TO SECOND), EXTRACT(MINUTE FROM INTERVAL '3 04:05:06' DAY TO SECOND), EXTRACT(SECOND FROM INTERVAL '3 04:05:06' DAY TO SECOND)"] {{1 2 3 4 5 6}}
check iv_arith  [rows "SELECT INTERVAL '1' DAY + INTERVAL '2' HOUR, INTERVAL '1' DAY - INTERVAL '2' HOUR, INTERVAL '1' DAY * 3, 2 * INTERVAL '1' HOUR, INTERVAL '1' DAY / 2, -INTERVAL '1' HOUR"] [list [list {1 day 02:00:00} 22:00:00 {3 days} 02:00:00 12:00:00 -01:00:00]]
check iv_cmp    [rows "SELECT INTERVAL '1' DAY < INTERVAL '25' HOUR, INTERVAL '2' HOUR = INTERVAL '120' MINUTE, INTERVAL '1' MONTH > INTERVAL '29' DAY, INTERVAL '1' DAY <> INTERVAL '1' DAY"] {{1 1 1 0}}
check iv_order  [col0 "SELECT x FROM (SELECT INTERVAL '3' DAY AS x UNION ALL SELECT INTERVAL '1' DAY UNION ALL SELECT INTERVAL '2' HOUR) t ORDER BY x"] {02:00:00 {1 day} {3 days}}
check iv_text   [rows "SELECT 'x' || INTERVAL '1' DAY, CAST(INTERVAL '2' DAY AS VARCHAR)"] {{{x1 day} {2 days}}}
check iv_cast   [one "SELECT CAST('3 days' AS INTERVAL) + DATE '2026-03-05'"] 2026-03-08
check iv_null   [rows "SELECT NULL + INTERVAL '1' DAY, DATE '2026-03-05' + NULL"] {{NULL NULL}}
check dt_col    [col0 "SELECT CAST(hired AS DATE) + INTERVAL '7' DAY FROM employees WHERE id = 3"] {2011-04-13}
check dt_filter [llength [rows "SELECT id FROM employees WHERE CAST(hired AS DATE) >= CURRENT_DATE - INTERVAL '100' YEAR"]] 20
check dt_now    [expr {[one "SELECT CURRENT_DATE - CURRENT_DATE"] eq "00:00:00"}] 1
check dt_store  [ok "CREATE TABLE ev (id INT, at TIMESTAMP, note VARCHAR(40))"] ok
q "INSERT INTO ev VALUES (1, TIMESTAMP '2026-03-05 10:00:00' + INTERVAL '1' DAY, INTERVAL '2' DAY), (2, '2026-12-31', 'x')"
check dt_stored [rows "SELECT at, note FROM ev ORDER BY id"] [list [list {2026-03-06 10:00:00} {2 days}] [list 2026-12-31 x]]
check dt_sort_stored [col0 "SELECT id FROM ev ORDER BY at DESC"] {2 1}
check dt_stored_math [one "SELECT CAST(at AS TIMESTAMP) - TIMESTAMP '2026-03-01 00:00:00' FROM ev WHERE id = 1"] {5 days 10:00:00}
q "DROP TABLE ev"
check dt_e_col   [errmsg "CREATE TABLE ev (id INT, len INTERVAL)"] {INTERVAL columns are not supported; store the length as a number of seconds or as text}
check dt_e_plus  [errmsg "SELECT INTERVAL '1' DAY + 5"] {The operator + cannot be used between interval and int}
check dt_e_cmp   [errmsg "SELECT INTERVAL '1' DAY < 5"] {An interval can only be compared with another interval}
check dt_e_bad   [errmsg "SELECT INTERVAL 'abc'"] {Invalid interval 'abc'}
check dt_e_qual  [errmsg "SELECT INTERVAL '1-2' DAY"] {Invalid interval '1-2': expected a number of days}
check dt_e_date  [errmsg "SELECT DATE '2026-02-30' + INTERVAL '1' DAY"] {Invalid date 2026-02-30}
check dt_e_sum   [errmsg "SELECT SUM(x) FROM (SELECT INTERVAL '3' DAY AS x) t"] {SUM() over intervals is not supported}
check dt_e_timemonth [errmsg "SELECT TIME '10:00:00' + INTERVAL '1' MONTH"] {A month interval cannot be added to a TIME}
check dt_e_bareval [string match "'abc' is not a date or time*" [errmsg "SELECT CAST('abc' AS DATE) + INTERVAL '1' DAY"]] 0

# ============================================================================
#  Subqueries over grouped columns, and the scan cache
# ============================================================================
check grp_sub   [rows "SELECT dept, (SELECT name FROM departments d WHERE d.id = e.dept), COUNT(*) FROM employees e GROUP BY dept ORDER BY dept"] {{1 Engineering 4} {2 Design 4} {3 Sales 4} {4 Support 4} {5 Research 4}}
check grp_sub_having [rows "SELECT dept FROM employees e GROUP BY dept HAVING EXISTS (SELECT 1 FROM departments d WHERE d.id = e.dept AND d.location = 'Berlin')"] {1}
check grp_sub_nonequi [rows "SELECT dept, (SELECT COUNT(*) FROM employees x WHERE x.dept > e.dept) FROM employees e GROUP BY dept ORDER BY dept"] {{1 16} {2 12} {3 8} {4 4} {5 0}}
check grp_sub_err [errmsg "SELECT dept, (SELECT name FROM departments d WHERE d.id = e.id) FROM employees e GROUP BY dept"] {Column 'id' must appear in the GROUP BY clause or be used in an aggregate function (it is used inside a subquery)}
check grp_sub_in [col0 "SELECT dept FROM employees e GROUP BY dept HAVING dept IN (SELECT id FROM departments WHERE id < 3) ORDER BY dept"] {1 2}
check scan_cache [rows "SELECT d.id, (SELECT COUNT(*) FROM departments x WHERE x.id > d.id) FROM departments d ORDER BY d.id"] {{1 4} {2 3} {3 2} {4 1} {5 0}}
check scan_cache2 [col0 "SELECT d.id FROM departments d WHERE NOT EXISTS (SELECT 1 FROM departments x WHERE x.id > d.id AND x.name < d.name) ORDER BY d.id"] [col0 "SELECT d.id FROM departments d WHERE d.id NOT IN (SELECT a.id FROM departments a JOIN departments b ON b.id > a.id AND b.name < a.name) ORDER BY d.id"]

# cancelling a long-running correlated query (the UI sets ::mkitsql::cancel from its progress hook)
q "CREATE TABLE cx (n INT)"
q "INSERT INTO cx SELECT id FROM employees"
for {set i 0} {$i < 6} {incr i} { q "INSERT INTO cx SELECT n + $i * 100 FROM cx" }
set mkitsql::progressHook {set ::mkitsql::cancel 1}
check cancel_corr [errmsg "SELECT COUNT(*) FROM cx a WHERE a.n > (SELECT AVG(n) FROM cx b WHERE b.n < a.n)"] {Cancelled}
set mkitsql::progressHook {}
check cancel_reset [one "SELECT COUNT(*) FROM cx WHERE n < 0"] 0
q "DROP TABLE cx"

# ============================================================================
#  LATERAL
# ============================================================================
check lat_topn   [rows "SELECT d.id, t.id FROM departments d CROSS JOIN LATERAL (SELECT e.id FROM employees e WHERE e.dept = d.id ORDER BY e.id DESC LIMIT 2) t ORDER BY d.id, t.id"] [
    set o {} ; foreach d {1 2 3 4 5} { set ids {} ; foreach r $emp { if {[lindex $r 3] == $d} { lappend ids [lindex $r 0] } }
        foreach i [lrange [lsort -integer -decreasing $ids] 0 1] { lappend o [list $d $i] } } ; lsort -index 0 -integer [lsort -index 1 -integer $o]]
check lat_comma  [rows "SELECT d.id, t.id FROM departments d, LATERAL (SELECT e.id FROM employees e WHERE e.dept = d.id AND e.id <= 3) t ORDER BY d.id"] {{2 3} {3 1} {5 2}}
check lat_left   [rows "SELECT d.id, t.n FROM departments d LEFT JOIN LATERAL (SELECT COUNT(*) AS n FROM employees e WHERE e.dept = d.id AND e.id > 18) t ON 1 = 1 ORDER BY d.id"] {{1 1} {2 0} {3 0} {4 1} {5 0}}
check lat_left_null [col0 "SELECT d.id FROM departments d LEFT JOIN LATERAL (SELECT e.id FROM employees e WHERE e.dept = d.id AND e.id > 1000) t ON 1 = 1 WHERE t.id IS NULL ORDER BY d.id"] {1 2 3 4 5}
check lat_on     [rows "SELECT d.id, t.v FROM departments d JOIN LATERAL (SELECT d.id * 10 AS v) t ON t.v > 20 ORDER BY d.id"] {{3 30} {4 40} {5 50}}
check lat_same   [rows "SELECT d.id, (SELECT COUNT(*) FROM employees e WHERE e.dept = d.id) FROM departments d ORDER BY d.id"] [rows "SELECT d.id, t.n FROM departments d CROSS JOIN LATERAL (SELECT COUNT(*) AS n FROM employees e WHERE e.dept = d.id) t ORDER BY d.id"]
check lat_first  [rows "SELECT * FROM LATERAL (SELECT 1 AS x) t"] {1}
check lat_nested [rows "SELECT d.id, t.m FROM departments d, LATERAL (SELECT MAX(e.id) AS m FROM employees e, LATERAL (SELECT 1 AS one) z WHERE e.dept = d.id) t ORDER BY d.id"] [rows "SELECT d.id, (SELECT MAX(e.id) FROM employees e WHERE e.dept = d.id) FROM departments d ORDER BY d.id"]
check lat_right  [errmsg "SELECT 1 FROM departments d RIGHT JOIN LATERAL (SELECT 1 AS x) t ON 1 = 1"] {RIGHT / FULL JOIN is not supported with LATERAL}
check lat_nosub  [expr {[errmsg "SELECT 1 FROM departments d, LATERAL employees e"] ne "(no error)"}] 1

# ============================================================================
#  MERGE
# ============================================================================
q "CREATE TABLE stock (sku VARCHAR(10), qty INT, note VARCHAR(20))"
q "INSERT INTO stock VALUES ('a', 10, ''), ('b', 5, ''), ('c', 0, ''), ('d', 7, '')"
q "CREATE TABLE incoming (sku VARCHAR(10), qty INT)"
q "INSERT INTO incoming VALUES ('a', 5), ('c', 0), ('e', 9), ('f', 0)"
set r [q "MERGE INTO stock s USING incoming i ON s.sku = i.sku
          WHEN MATCHED AND i.qty = 0 THEN DELETE
          WHEN MATCHED THEN UPDATE SET qty = s.qty + i.qty, note = 'restocked'
          WHEN NOT MATCHED AND i.qty > 0 THEN INSERT (sku, qty, note) VALUES (i.sku, i.qty, 'new')"]
check merge_msg  [dict get $r text] {MERGE into 'stock': 1 updated, 1 deleted, 1 inserted.}
check merge_rows [rows "SELECT sku, qty, note FROM stock ORDER BY sku"] {{a 15 restocked} {b 5 {}} {d 7 {}} {e 9 new}}
check merge_affected [dict get $r affected] 3
q "MERGE INTO stock USING (SELECT 'b' AS sku, 100 AS qty) i ON stock.sku = i.sku WHEN MATCHED THEN UPDATE SET qty = i.qty"
check merge_subq [one "SELECT qty FROM stock WHERE sku = 'b'"] 100
q "MERGE INTO stock USING (VALUES ('z', 1)) AS v(sku, qty) ON stock.sku = v.sku WHEN NOT MATCHED THEN INSERT VALUES (v.sku, v.qty, 'v')"
check merge_values [rows "SELECT sku, qty, note FROM stock WHERE sku = 'z'"] {{z 1 v}}
check merge_none [dict get [q "MERGE INTO stock USING incoming i ON stock.sku = i.sku AND 1 = 0 WHEN MATCHED THEN DELETE"] affected] 0
check merge_twice [errmsg "MERGE INTO stock s USING (SELECT 'a' AS sku UNION ALL SELECT 'a') i ON s.sku = i.sku WHEN MATCHED THEN UPDATE SET qty = 0"] {MERGE would change the same target row twice: the ON condition matches one target row with more than one source row}
check merge_atomic [one "SELECT qty FROM stock WHERE sku = 'a'"] 15
check merge_badcol [string match "Unknown column 'nope' in 'stock'" [errmsg "MERGE INTO stock s USING incoming i ON s.sku = i.sku WHEN MATCHED THEN UPDATE SET nope = 1"]] 1
check merge_badtype [string match "Column 'qty' holds whole numbers*" [errmsg "MERGE INTO stock s USING incoming i ON s.sku = i.sku WHEN MATCHED THEN UPDATE SET qty = 'x'"]] 1
check merge_valcount [string match "MERGE ... INSERT has 2 columns but 1 value" [errmsg "MERGE INTO stock s USING incoming i ON s.sku = i.sku WHEN NOT MATCHED THEN INSERT (sku, qty) VALUES (i.sku)"]] 1
check merge_noclause [string match "MERGE needs at least one*" [errmsg "MERGE INTO stock s USING incoming i ON s.sku = i.sku"]] 1
check merge_dirty [expr {[store::dirty $db] > 0}] 1
q "DROP TABLE stock"
q "DROP TABLE incoming"

# ============================================================================
#  Subviews (Metakit's nested tables)
# ============================================================================
set r [q "SELECT id, skills FROM employees WHERE id = 1"]
check subcell [dict get $r rows] [list [list 1 "\u25B8 2 rows"]]
check subdrill [dict get $r drill] {1 skills}
check subwhere [col0 "SELECT id FROM employees WHERE skills >= 4 ORDER BY id"] {3 7 11 15 19}
check lateral1 [llength [rows "SELECT e.id, s.skill FROM employees e JOIN e.skills s ON 1 = 1"]] [
    set n 0 ; for {set i 0} {$i < 20} {incr i} { incr n [store::size $db.employees!$i.skills] } ; set n]
check lateral2 [rows "SELECT s.skill, s.level FROM employees e, e.skills s WHERE e.id = 1 ORDER BY s.skill"] [rows "SELECT skill, level FROM employees\[0\].skills ORDER BY skill"]
check lateral_left [llength [rows "SELECT e.id FROM employees e LEFT JOIN e.skills s ON s.level > 100"]] 20
check lateral_agg [rows "SELECT e.name, COUNT(*), MAX(s.level) FROM employees e JOIN e.skills s ON 1 = 1 WHERE e.id = 3 GROUP BY e.name"] [list [list "Alan Turing" 4 [tcl::mathfunc::max {*}[lmap_ [store::rows $db.employees!2.skills {level} 0 10] {x {lindex $x 0}}]]]]
check lateral_nonsub [errmsg "SELECT * FROM employees e JOIN e.name n ON 1 = 1"] {'e' has no subview column 'name'}
check subpath [rows "SELECT skill FROM $db.employees\[0\].skills ORDER BY skill"] [rows "SELECT skill FROM employees\[0\].skills ORDER BY skill"]
check subcount [rows "SELECT COUNT(*) FROM orders\[0\].lines"] {2}
check subrow_err [errmsg "SELECT * FROM employees\[999\].skills"] {Row 999 does not exist in 'employees' (it has 20 rows)}
check subinsert [ok "INSERT INTO employees\[0\].skills (skill, level) VALUES ('Go', 3)"] ok
check subinsert2 [one "SELECT COUNT(*) FROM employees\[0\].skills"] 3
check subupdate [ok "UPDATE employees\[0\].skills SET level = level + 1 WHERE skill = 'Go'"] ok
check subupdate2 [one "SELECT level FROM employees\[0\].skills WHERE skill = 'Go'"] 4
check subdelete [ok "DELETE FROM employees\[0\].skills WHERE skill = 'Go'"] ok
check subdelete2 [one "SELECT COUNT(*) FROM employees\[0\].skills"] 2

# ============================================================================
#  Plain results carry row ids / source for the grid
# ============================================================================
set r [q "SELECT name FROM employees WHERE id > 18 ORDER BY id"]
check ids_plain [list [dict get $r rowids] [dict get $r source] [dict get $r editable]] [list {18 19} $db.employees 1]
set r [q "SELECT dept, COUNT(*) FROM employees GROUP BY dept"]
check ids_agg [list [dict get $r rowids] [dict get $r source] [dict get $r editable]] [list {} {} 0]
set r [q "SELECT * FROM orders\[1\].lines"]
check ids_sub [dict get $r source] $db.orders!1.lines
check coltypes [dict get [q "SELECT id, name, salary, id + 1, 'x' FROM employees LIMIT 1"] types] {I S D N {}}
check trunc [dict get [q "SELECT 1"] truncated] 0
set mkitsql::maxRows 5
check cap_plain [list [llength [rows "SELECT id FROM employees"]] [dict get [q "SELECT id FROM employees"] truncated]] {5 1}
check cap_limit [list [llength [rows "SELECT id FROM employees LIMIT 7"]] [dict get [q "SELECT id FROM employees LIMIT 7"] truncated]] {5 1}
set mkitsql::maxRows 100000

# ============================================================================
#  INSERT / UPDATE / DELETE
# ============================================================================
check ins   [dict get [q "INSERT INTO products (sku, name, price, stock) VALUES ('X-1', 'Test', 1.5, 7), ('X-2', 'Two', 2, 8)"] affected] 2
check ins2  [rows "SELECT sku, discontinued FROM products WHERE sku LIKE 'X-%' ORDER BY sku"] {{X-1 0} {X-2 0}}
check ins_noCols [ok "INSERT INTO products VALUES ('X-3', 'Three', 3, 9, 1)"] ok
check ins_noCols2 [rows "SELECT sku, discontinued FROM products WHERE sku = 'X-3'"] {{X-3 1}}
check ins_select [dict get [q "INSERT INTO products (sku, name, price, stock) SELECT 'Y-' || id, name, 1, id FROM departments"] affected] 5
check ins_select2 [one "SELECT COUNT(*) FROM products WHERE sku LIKE 'Y-%'"] 5
check ins_expr [ok "INSERT INTO products (sku, name, price, stock) VALUES ('Z-1', UPPER('z'), 2 * 3, 10 / 3)"] ok
check ins_expr2 [rows "SELECT name, price = 6, stock FROM products WHERE sku = 'Z-1'"] {{Z 1 3}}
check ins_null [ok "INSERT INTO products (sku, name, price, stock) VALUES ('N-1', NULL, NULL, NULL)"] ok
check ins_null2 [rows "SELECT name, price = 0, stock FROM products WHERE sku = 'N-1'"] {{{} 1 0}}
check ins_defaults [ok "INSERT INTO products DEFAULT VALUES"] ok
check ins_textnum [ok "INSERT INTO products (sku, name, price, stock) VALUES ('T-1', 'n', '2.5', '42')"] ok
check ins_textnum2 [rows "SELECT price, stock FROM products WHERE sku = 'T-1'"] {{2.5 42}}
check ins_integral_real [ok "INSERT INTO products (sku, stock) VALUES ('T-2', 5.0)"] ok
check ins_bad_type [errmsg "INSERT INTO products (sku, stock) VALUES ('a', 'many')"] {Column 'stock' holds whole numbers (INTEGER), but 'many' is not a whole number}
check ins_frac [errmsg "INSERT INTO products (sku, stock) VALUES ('a', 1.5)"] {Column 'stock' holds whole numbers (INTEGER), but '1.5' is not a whole number}
check ins_range [string match "Value 3000000000 is out of range for 32-bit INTEGER*" [errmsg "INSERT INTO products (sku, stock) VALUES ('a', 3000000000)"]] 1
check ins_unknown [string match "Unknown column 'nope' in 'products'.*" [errmsg "INSERT INTO products (nope) VALUES (1)"]] 1
check ins_count [errmsg "INSERT INTO products (sku, name) VALUES ('a')"] {INSERT has 2 target columns but the source provides 1 value}
check ins_count2 [errmsg "INSERT INTO products (sku, name) VALUES ('a', 'b'), ('c')"] {All rows in VALUES must have the same number of columns}
check ins_width [errmsg "INSERT INTO products (sku, name) SELECT 1 FROM departments"] {INSERT has 2 target columns but the source provides 1 value}
check ins_dup [errmsg "INSERT INTO products (sku, sku) VALUES ('a', 'b')"] {Column 'sku' is listed twice}
set before [one "SELECT COUNT(*) FROM products"]
check ins_atomic [ok "INSERT INTO products (sku, stock) VALUES ('ok1', 1), ('ok2', 2), ('bad', 'x')"] "ERROR: Column 'stock' holds whole numbers (INTEGER), but 'x' is not a whole number"
check ins_atomic2 [one "SELECT COUNT(*) FROM products"] $before
check ins_col_expr [string match "Unknown column*" [errmsg "INSERT INTO products (sku) VALUES (name)"]] 1
check upd   [dict get [q "UPDATE products SET stock = stock + 10, price = price * 2 WHERE sku = 'X-1'"] affected] 1
check upd2  [rows "SELECT stock, price FROM products WHERE sku = 'X-1'"] {{17 3.0}}
check upd_swap [ok "UPDATE products SET stock = discontinued, discontinued = stock WHERE sku = 'X-3'"] ok
check upd_swap2 [rows "SELECT stock, discontinued FROM products WHERE sku = 'X-3'"] {{1 9}}
check upd_all [dict get [q "UPDATE products SET name = UPPER(name) WHERE sku LIKE 'Y-%'"] affected] 5
check upd_sub [ok "UPDATE products SET stock = (SELECT COUNT(*) FROM departments) WHERE sku = 'X-2'"] ok
check upd_sub2 [one "SELECT stock FROM products WHERE sku = 'X-2'"] 5
check upd_alias [ok "UPDATE products p SET stock = 99 WHERE p.sku = 'X-2'"] ok
check upd_alias2 [one "SELECT stock FROM products WHERE sku = 'X-2'"] 99
check upd_null [ok "UPDATE products SET name = NULL WHERE sku = 'X-2'"] ok
check upd_null2 [one "SELECT name FROM products WHERE sku = 'X-2'"] {}
check upd_bad [errmsg "UPDATE products SET stock = 'x'"] "Column 'stock' holds whole numbers (INTEGER), but 'x' is not a whole number"
check upd_atomic [one "SELECT COUNT(*) FROM products WHERE stock = 0"] [one "SELECT COUNT(*) FROM products WHERE stock = 0"]
check upd_unknown [string match "Unknown column 'zzz' in 'products'.*" [errmsg "UPDATE products SET zzz = 1"]] 1
check upd_dup [errmsg "UPDATE products SET stock = 1, stock = 2"] {Column 'stock' is assigned twice}
check upd_subview [string match "'skills' is a subview*" [errmsg "UPDATE employees SET skills = 3"]] 1
check del   [dict get [q "DELETE FROM products WHERE sku LIKE 'X-%' OR sku LIKE 'Y-%' OR sku LIKE 'Z-%' OR sku LIKE 'T-%' OR sku LIKE 'N-%'"] affected] 12
check del_all [dict get [q "DELETE FROM products WHERE name = '' AND sku = ''"] affected] 1
check del2  [one "SELECT COUNT(*) FROM products"] 8
check del_sub [ok "DELETE FROM employees WHERE id IN (SELECT 1)"] ok
check del_sub2 [one "SELECT COUNT(*) FROM employees"] 19
check trunc_table [ok "TRUNCATE TABLE products"] ok
check trunc2 [one "SELECT COUNT(*) FROM products"] 0
check dirty [expr {[store::dirty $db] > 0}] 1

# ============================================================================
#  DDL
# ============================================================================
q "CREATE TABLE notes (id INT, body VARCHAR(100), tags TABLE (tag TEXT, weight DOUBLE PRECISION), big BIGINT, r REAL, d DATE, ok BOOLEAN, blobby BLOB)"
check create [store::layout $db.notes] {{id I {}} {body S {}} {tags V {{tag S {}} {weight D {}}}} {big L {}} {r F {}} {d S {}} {ok I {}} {blobby B {}}}
check create_exists [errmsg "CREATE TABLE notes (a INT)"] "Table 'notes' already exists in '$db'."
check create_ine [dict get [q "CREATE TABLE IF NOT EXISTS notes (a INT)"] affected] 0
check create_dup_col [errmsg "CREATE TABLE zz (a INT, A TEXT)"] {Column 'A' is defined twice}
check create_bare_sub [ok "CREATE TABLE zz (a INT, kids (name TEXT, age INT))"] ok
check create_zz [store::layout $db.zz] {{a I {}} {kids V {{name S {}} {age I {}}}}}
q "DROP TABLE zz"
check ctas [dict get [q "CREATE TABLE top3 AS SELECT id, name AS who, salary * 2 AS pay, id > 1 AS flag FROM employees ORDER BY id LIMIT 3"] affected] 3
check ctas_layout [store::layout $db.top3] {{id I {}} {who S {}} {pay D {}} {flag I {}}}
check ctas_rows [col0 "SELECT who FROM top3 ORDER BY id"] [lrange [lmap_ [lsort -integer -index 0 [store::rows $db.employees {id name} 0 100]] {r {lindex $r 1}}] 0 2]
check ctas_dup [errmsg "CREATE TABLE top4 AS SELECT 1 AS a, 2 AS a"] {Column 'a' appears twice; give one an alias}
check ctas_expr_name [string match "Column name '1 + 1' is not allowed*" [errmsg "CREATE TABLE top5 AS SELECT 1 + 1"]] 1
q "DROP TABLE top3"
check name_space [string match "Column name 'first name' is not allowed*" [errmsg {CREATE TABLE sp ("first name" TEXT)}]] 1
check name_table [string match "Table name 'a b' is not allowed*" [errmsg {CREATE TABLE "a b" (x INT)}]] 1
check name_reserved_ok [ok {CREATE TABLE "select" ("from" INT, "order" TEXT)}] ok
q {INSERT INTO "select" ("from", "order") VALUES (1, 'x')}
check name_reserved_sel [rows {SELECT "from", "order" FROM "select" WHERE "from" > 0}] {{1 x}}
q {DROP TABLE "select"}
check utf8 [rows "SELECT UPPER('h\u00e9llo'), LENGTH('h\u00e9llo')"] [list [list "H\u00c9LLO" 5]]
check drop [store::hasView $db zz] 0
# a dropped table must not leave its rows behind for a new table of the same name
q "CREATE TABLE ghost (a INT, b TEXT)"
q "INSERT INTO ghost VALUES (1, 'x'), (2, 'y')"
q "DROP TABLE ghost"
q "CREATE TABLE ghost (a INT, b TEXT)"
check drop_recreate_empty [one "SELECT COUNT(*) FROM ghost"] 0
q "DROP TABLE ghost"
q "COMMIT"
q "CREATE TABLE ghost (a INT, c TEXT)"
check drop_recreate_committed [one "SELECT COUNT(*) FROM ghost"] 0
q "DROP TABLE ghost"
check drop_missing [string match "Unknown table 'zz'*" [errmsg "DROP TABLE zz"]] 1
check drop_ie [ok "DROP TABLE IF EXISTS zz"] ok
q "INSERT INTO notes (id, body) VALUES (1, 'hello'), (2, 'it''s quoted')"
check quote [rows "SELECT body FROM notes WHERE id = 2"] [list [list "it's quoted"]]
q "ALTER TABLE notes ADD COLUMN flag INT"
check addcol [lindex [store::layout $db.notes] end] {flag I {}}
check addcol_default [one "SELECT flag FROM notes WHERE id = 1"] 0
q "ALTER TABLE notes RENAME COLUMN body TO text"
check ren [rows "SELECT text FROM notes WHERE id = 1"] {hello}
q "ALTER TABLE notes ALTER COLUMN id SET DATA TYPE VARCHAR"
check retype [rows "SELECT id FROM notes ORDER BY id"] {1 2}
q "ALTER TABLE notes DROP COLUMN flag"
check dropcol [lsearch -exact [lmap_ [store::layout $db.notes] {c {lindex $c 0}}] flag] -1
check alter_unknown [string match "Unknown column 'nope' in 'notes'." [errmsg "ALTER TABLE notes DROP COLUMN nope"]] 1
q "ALTER TABLE notes RENAME TO memos"
check rename_table [list [store::hasView $db notes] [store::hasView $db memos] [one "SELECT COUNT(*) FROM memos"]] {0 1 2}
check rename_keeps_layout [llength [store::layout $db.memos]] 8
q "DROP TABLE memos"
check constraint_pk [string match "PRIMARY KEY is not supported*" [errmsg "CREATE TABLE k (id INT PRIMARY KEY)"]] 1
check constraint_nn [string match "NOT NULL is not supported*" [errmsg "CREATE TABLE k (id INT NOT NULL)"]] 1
set mkitsql::ignoreConstraints 1
check constraint_ign [ok "CREATE TABLE k (id INT PRIMARY KEY, v TEXT NOT NULL DEFAULT 'x', UNIQUE (v))"] ok
set mkitsql::ignoreConstraints 0
q "DROP TABLE k"
check index_err [string match "CREATE INDEX is not supported*" [errmsg "CREATE INDEX i ON products (sku)"]] 1
check view_err [string match "CREATE VIEW is not supported*" [errmsg "CREATE VIEW v AS SELECT 1"]] 1

# ============================================================================
#  information_schema, SHOW, DESCRIBE
# ============================================================================
check is_tables [col0 "SELECT table_name FROM information_schema.tables ORDER BY table_name"] {departments employees orders products}
check is_cols [col0 "SELECT column_name FROM information_schema.columns WHERE table_name = 'products' ORDER BY ordinal_position"] {sku name price stock discontinued}
check showtables [llength [rows "SHOW TABLES"]] 4
check showdbs [lindex [rows "SHOW DATABASES"] 0 0] [store::tags]
check describe [lrange [lindex [rows "DESCRIBE products"] 0] 0 3] {1 sku VARCHAR column}

# ============================================================================
#  Transactions
# ============================================================================
q "COMMIT"
check clean [store::dirty $db] 0
q "BEGIN"
q "DELETE FROM orders"
check wiped [one "SELECT COUNT(*) FROM orders"] 0
q "ROLLBACK"
check rolled [one "SELECT COUNT(*) FROM orders"] 18
q "DELETE FROM orders WHERE id = 1001"
q "COMMIT WORK"
store::closeFile $db
set db [store::openFile $f]
check persisted [one "SELECT COUNT(*) FROM orders"] 17
check nothing_to_commit [dict get [q "COMMIT"] text] {Nothing to commit: there are no pending changes.}
set mkitsql::autocommit 1
q "INSERT INTO departments (id, name) VALUES (9, 'Auto')"
check autocommit [store::dirty $db] 0
set mkitsql::autocommit 0
q "DELETE FROM departments WHERE id = 9"
q "COMMIT"

# ============================================================================
#  Parameters
# ============================================================================
check param_pos [rows "SELECT name FROM employees WHERE id = ?" {3}] {{{Alan Turing}}}
check param_two [rows "SELECT id FROM employees WHERE id > ? AND id < ? ORDER BY id" {1 4}] {2 3}
check param_named [rows "SELECT name FROM employees WHERE id = :id" {id 2}] {{{Grace Hopper}}}
check param_text [rows "SELECT id FROM employees WHERE name = ?" {{Alan Turing}}] {3}
check param_two_ints [rows "SELECT id FROM employees WHERE id > ? AND id < ? ORDER BY id" {3 6}] {4 5}
check param_strings [rows "SELECT id FROM departments WHERE name = ? OR name = ? ORDER BY id" {Sales Design}] {2 3}
check param_named_multi [rows "SELECT id FROM employees WHERE id > :lo AND id < :hi ORDER BY id" {lo 3 hi 6}] {4 5}
check param_named_reuse [rows "SELECT id FROM employees WHERE id = :x OR id = :x + 1 ORDER BY id" {x 7}] {7 8}
check param_mix  [errmsg "SELECT ? + :a"] {A statement cannot mix ? and :name parameters}
check param_odd  [errmsg "SELECT :a" {a}] {Named parameters must be given as a dict of name value pairs}
check param_extra [rows "SELECT 1" {5 6}] {1}
check param_null [rows "SELECT ? IS NULL" [list $mkitsql::N]] {1}
check param_query_api [dict get [mkitsql::query "SELECT name FROM departments WHERE id = ?" $db {3}] rows] {Sales}
check param_miss [errmsg "SELECT ?"] {No value was supplied for parameter #1}
check param_ins [ok "INSERT INTO departments (id, name) VALUES (?, ?)"] "ERROR: No value was supplied for parameter #1"
check param_inj [rows "SELECT id FROM employees WHERE name = ?" {{x' OR '1'='1}}] {}

# ============================================================================
#  Errors and syntax positions
# ============================================================================
check e_unknown_stmt [string match "Unknown statement 'SELEC'*" [errmsg "SELEC 1"]] 1
check e_col [string match "Unknown column 'nope'.  Available: *" [errmsg "SELECT nope FROM employees"]] 1
check e_col_q [string match "Unknown column 'nope' in 'employees'.  Available: *" [errmsg "SELECT employees.nope FROM employees"]] 1
check e_table [string match "Unknown table 'zzz'.*" [errmsg "SELECT * FROM zzz"]] 1
check e_db [string match "Unknown database 'nodb'. Open databases: *" [errmsg "SELECT * FROM nodb.products"]] 1
check e_alias [errmsg "SELECT x.id FROM employees"] {Unknown table or alias 'x' in reference 'x.id'}
check e_expr [errmsg "SELECT * FROM employees WHERE"] {Expression expected}
check e_str [errmsg "SELECT 'oops"] {Unterminated string literal}
check e_fn [errmsg "SELECT FROBNICATE(1)"] {Unknown function FROBNICATE()}
check e_fn_args [errmsg "SELECT UPPER('a', 'b')"] {Function UPPER() takes 1 argument, not 2}
check e_limit [errmsg "SELECT 1 LIMIT -1"] {LIMIT must be a non-negative whole number}
check e_star [errmsg "SELECT * "] {SELECT * needs a FROM clause}
check e_nofrom_col [string match "Unknown column 'a'*" [errmsg "SELECT a"]] 1
check e_order_pos [errmsg "SELECT id FROM employees ORDER BY 3"] {ORDER BY position 3 is out of range (1 to 1)}
check e_bool [errmsg "SELECT * FROM employees WHERE name"] {A condition (WHERE, HAVING, ON) must be true/false or a number, not text}
check e_bool_having [errmsg "SELECT dept FROM employees GROUP BY dept HAVING dept || 'x'"] {A condition (WHERE, HAVING, ON) must be true/false or a number, not text}
check num_cond [col0 "SELECT id FROM employees WHERE id - 18 ORDER BY id LIMIT 3"] {2 3 4}
check num_cond0 [rows "SELECT 1 WHERE 0"] {}
catch {mkitsql::parseScript "SELECT id FROM employees WHERE id = = 3"} m opts
check e_pos [dict get $opts -errorcode] {MKQL SYNTAX 36 1}
check e_script [llength [mkitsql::parseScript "SELECT 1; SELECT 2;; -- c\n SELECT 3 /* x */"]] 3

# ============================================================================
#  Read-only databases
# ============================================================================
store::closeFile $db
set ro [store::openFile $f -readonly]
check ro_write [errmsg "DELETE FROM orders"] "Database '$ro' is open read-only."
check ro_read [rows "SELECT COUNT(*) FROM departments" ] {5}
check ro_create [errmsg "CREATE TABLE t (a INT)"] "Database '$ro' is open read-only."
store::closeFile $ro
file delete $f

puts "\n$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
