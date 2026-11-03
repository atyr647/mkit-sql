# Robustness fuzzer:  tclsh tests/fuzz.tcl [mutations] [seed]
# Mutates valid statements (delete / duplicate / swap / insert tokens, truncate, random bytes) and
# runs each.  Every failure must be a CLEAN error: either an engine error (-errorcode MKQL ...) or a
# message about Metakit/data.  Raw Tcl internals ("can't read", "wrong # args", "invalid command
# name", ...) mean a bug.
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/vendor/store.tcl
source [file join [file dirname $here] mkitsql mkitsql.tcl]
set N [expr {$argc > 0 ? [lindex $argv 0] : 20000}]
expr {srand([expr {$argc > 1 ? [lindex $argv 1] : 1}])}
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_fuzz_[pid].mk
file delete $f
set db [store::createSample $f]
store::commit $db
set mkitsql::maxRecursion 50
set mkitsql::maxRows 500

set corpus {
 "SELECT id, name FROM employees WHERE id > 3 AND dept IN (1, 2) ORDER BY name DESC LIMIT 5 OFFSET 1"
 "SELECT dept, COUNT(*), AVG(salary), MAX(name) FROM employees GROUP BY dept HAVING COUNT(*) > 1 ORDER BY 2"
 "SELECT e.name, d.name FROM employees e LEFT JOIN departments d ON d.id = e.dept WHERE e.salary BETWEEN 50000 AND 90000"
 "SELECT * FROM employees e JOIN e.skills s ON s.level > 2"
 "SELECT name FROM employees WHERE salary > (SELECT AVG(salary) FROM employees) AND EXISTS (SELECT 1 FROM departments WHERE id = employees.dept)"
 "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 10) SELECT SUM(x) FROM n"
 "SELECT id, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC), SUM(salary) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM employees"
 "SELECT CASE WHEN id < 5 THEN 'a' ELSE 'b' END, CAST(id AS VARCHAR) || '-' || UPPER(name), ROUND(salary / 3, 2) FROM employees"
 "SELECT DATE '2026-03-05' + INTERVAL '1' MONTH, EXTRACT(DAY FROM DATE '2026-03-05' - DATE '2026-01-01'), INTERVAL '1 02:03:04' DAY TO SECOND"
 "SELECT x FROM (VALUES (1), (2), (3)) t(x) UNION SELECT dept FROM employees INTERSECT SELECT id FROM departments"
 "SELECT d.id, t.name FROM departments d CROSS JOIN LATERAL (SELECT name FROM employees e WHERE e.dept = d.id LIMIT 2) t"
 "SELECT id FROM employees WHERE (dept, id) IN (SELECT id, id FROM departments) OR salary > ANY (SELECT budget FROM departments)"
 "INSERT INTO products (sku, name, price, stock) VALUES ('Z-1', 'Zed', 1.5, 7), ('Z-2', 'Two', 2, 8)"
 "UPDATE products SET stock = stock + 10, price = price * 2 WHERE sku LIKE 'MK-%'"
 "DELETE FROM products WHERE stock < 0 OR sku = 'none'"
 "MERGE INTO products p USING (SELECT 'MK-001' AS sku, 5 AS qty) s ON p.sku = s.sku WHEN MATCHED THEN UPDATE SET stock = s.qty WHEN NOT MATCHED THEN INSERT (sku, stock) VALUES (s.sku, s.qty)"
 "CREATE TABLE tmpz (id INT, body TEXT, kids TABLE (k TEXT, w DOUBLE PRECISION))"
 "ALTER TABLE tmpz ADD COLUMN extra INT"
 "DROP TABLE IF EXISTS tmpz"
 "SELECT STRING_AGG(name, ', '), COUNT(*) FILTER (WHERE dept = 1) FROM employees"
 "SELECT * FROM information_schema.columns WHERE table_name = 'employees'"
 "SELECT COALESCE(NULLIF(dept, 3), 0) + MOD(id, 4) FROM employees ORDER BY 1 NULLS LAST"
 "SELECT name FROM employees WHERE name LIKE 'A%' ESCAPE '!' AND name NOT ILIKE '%z' AND id IS NOT NULL"
 "SELECT d.name FROM departments d WHERE d.id = :x OR d.id = ?"
}
set junk [list "(" ")" "," ";" "." "*" "+" "-" "/" "%" "=" "<" ">" "<>" "||" "'" "\"" "\[" "\]" "\{" "\}" "\\" "\$" "?" ":" \
    SELECT FROM WHERE AND OR NOT NULL JOIN ON GROUP BY ORDER HAVING OVER WITH UNION VALUES CASE WHEN END \
    0 1 08 -1 1e999 99999999999999999999 "''" x "\n" "\0"]
set internal {"can't read" "can't set" "wrong # args" "invalid command name" "bad option" "unknown or ambiguous" "expected integer" "expected floating" "key \"*\" not known" "bad index" "list element" "unmatched open" "extra characters after" "missing close" "syntax error in expression" "can't use non-numeric" "divide by zero" "domain error" "integer value too large" "invalid bareword" "bad class" "unmatched \[" "wrong # of" "can't unset" "no such variable" "not a valid" "called \"" "wrong type" "unknown subcommand" "invalid octal" "malformed bignum" "argument is not"}
# messages that are deliberate user-facing errors from the data layer
proc isInternal {msg} {
    foreach p $::internal { if {[string match "*$p*" $msg]} { return 1 } }
    return 0
}
proc mutate {sql} {
    set toks [regexp -all -inline {\S+} $sql]
    set n [llength $toks]
    if {$n == 0} { return [lindex $::junk [expr {int(rand() * [llength $::junk])}]] }
    switch [expr {int(rand() * 8)}] {
        0 { set i [expr {int(rand() * $n)}] ; set toks [lreplace $toks $i $i] }
        1 { set i [expr {int(rand() * $n)}] ; set toks [linsert $toks $i [lindex $toks $i]] }
        2 { set i [expr {int(rand() * $n)}] ; set j [expr {int(rand() * $n)}] ; set a [lindex $toks $i] ; lset toks $i [lindex $toks $j] ; lset toks $j $a }
        3 { set i [expr {int(rand() * ($n + 1))}] ; set toks [linsert $toks $i [lindex $::junk [expr {int(rand() * [llength $::junk])}]]] }
        4 { set toks [lrange $toks 0 [expr {int(rand() * $n)}]] }
        5 { set i [expr {int(rand() * $n)}] ; lset toks $i [lindex $::junk [expr {int(rand() * [llength $::junk])}]] }
        6 { set s [join $toks " "] ; set i [expr {int(rand() * [string length $s])}] ; return [string replace $s $i $i [lindex $::junk [expr {int(rand() * [llength $::junk])}]]] }
        7 { set i [expr {int(rand() * $n)}] ; set j [expr {min($n - 1, $i + int(rand() * 4))}] ; set toks [lreplace $toks $i $j] }
    }
    return [join $toks " "]
}
set bad 0 ; set ok 0 ; set clean 0 ; set seen [dict create] ; set nonengine [dict create] ; set seen2 [dict create]
for {set k 0} {$k < $N} {incr k} {
    set sql [lindex $corpus [expr {int(rand() * [llength $corpus])}]]
    for {set m [expr {1 + int(rand() * 3)}]} {$m > 0} {incr m -1} { set sql [mutate $sql] }
    if {[catch {mkitsql::run $sql $db {1 1}} res opts]} {
        set code [dict get $opts -errorcode]
        # engine errors (MKQL ...) are clean by construction; anything else must not look like a Tcl internal
        if {[lindex $code 0] ne "MKQL"} {
            dict incr nonengine [string range $res 0 90]
            if {[info exists ::env(FUZZ_SHOW)] && ![dict exists $seen2 [string range $res 0 30]]} { dict set seen2 [string range $res 0 30] 1 ; puts "NONENGINE: $res\n   sql: $sql" }
        }
        if {[lindex $code 0] eq "MKQL" || ![isInternal $res]} {
            incr clean
        } else {
            incr bad
            set key [string range $res 0 60]
            if {![dict exists $seen $key]} { dict set seen $key 1 ; puts "INTERNAL ERROR: $res\n   code: $code\n   sql:  $sql" }
        }
    } else { incr ok }
    if {$k % 50 == 0} { catch {mkitsql::run "ROLLBACK" $db} }
}
store::closeFile $db ; file delete $f
if {[info exists ::env(FUZZ_SHOW)]} { dict for {m c} $nonengine { puts [format "%6d  %s" $c $m] } }
puts "$N mutated statements: $ok ran, $clean rejected cleanly, $bad INTERNAL errors"
exit [expr {$bad ? 1 : 0}]
