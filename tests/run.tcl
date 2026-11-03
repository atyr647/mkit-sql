# mkit-sql test suite.   Run:   tclsh tests/run.tcl [pattern]
#
# Runs against tests/vendor/mock_mk4tcl.tcl, a pure-Tcl stand-in for Mk4tcl
# (taken from MK Studio).  See README.md: this has NOT yet been run against the
# real Mk4tcl library.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
if {[info exists ::env(MKIT_MK4TCL)] && $::env(MKIT_MK4TCL) ne ""} {
    # run against a real Mk4tcl: MKIT_MK4TCL=/path/to/Mk4tcl.so
    load $::env(MKIT_MK4TCL) Mk4tcl
    puts "(using the real Mk4tcl: $::env(MKIT_MK4TCL))"
} else {
    source $here/vendor/mock_mk4tcl.tcl
}
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
proc errmsg {sql} { if {[catch {q $sql} m]} { return $m } ; return "(no error)" }
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
check e_window [string match "*not supported*" [errmsg "SELECT ROW_NUMBER() OVER (ORDER BY id) FROM employees"]] 1

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
