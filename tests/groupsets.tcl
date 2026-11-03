# GROUP BY ROLLUP / CUBE / GROUPING SETS / (), GROUPING(), combinations and error cases, checked against a brute-force reference.
#   tclsh tests/groupsets.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_gs_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 500]\n   want: [string range $want 0 500]" }
}
proc q {sql} { mkitsql::run $sql $::db }
proc err {sql} { if {[catch {q $sql} e]} { return $e } ; return "" }
q "CREATE TABLE t (a TEXT, b TEXT, c INT, v INT)"
expr {srand(11)}
set rows {} ; set vals {}
foreach i [lrepeat 60 0] {
    set r [list [lindex {x y z} [expr {int(rand()*3)}]] [lindex {p q} [expr {int(rand()*2)}]] [expr {int(rand()*3)}] [expr {int(rand()*100)}]]
    lappend rows $r ; lappend vals "('[lindex $r 0]', '[lindex $r 1]', [lindex $r 2], [lindex $r 3])"
}
q "INSERT INTO t VALUES [join $vals ,]"
q COMMIT
# reference: the rows of one grouping set.  cols = indexes of grouped columns among (a b c) = 0 1 2.  Output: a b c count sum grouping-mask
proc refSet {cols mask} {
    global rows
    set groups [dict create]
    foreach r $rows {
        set key {} ; foreach c $cols { lappend key [lindex $r $c] }
        dict lappend groups $key [lindex $r 3]
    }
    set out {}
    dict for {key vs} $groups {
        set o [list NULL NULL NULL] ; set k 0
        foreach c $cols { lset o $c [lindex $key $k] ; incr k }
        set s 0 ; foreach x $vs { incr s $x }
        lappend out [list {*}$o [llength $vs] $s $mask]
    }
    if {![llength $cols]} {
        set s 0 ; foreach r $rows { incr s [lindex $r 3] }
        set out [list [list NULL NULL NULL [llength $rows] $s $mask]]
    }
    return $out
}
# mask: bit for a (4), b (2), c (1): 1 when NOT grouped
# the mask is over the columns the query groups by at all (GROUPING() may only name those), leftmost = highest bit
set ::maskCols {0 1 2}
proc maskOf {cols} { set m 0 ; foreach c $::maskCols { set m [expr {($m << 1) | ($c in $cols ? 0 : 1)}] } ; return $m }
proc ref {sets} { set out {} ; foreach cols $sets { lappend out {*}[refSet $cols [maskOf $cols]] } ; return [lsort $out] }
proc sel {cols} {
    set ::maskCols $cols ; set names {}
    foreach c $cols { lappend names [lindex {a b c} $c] }
    set sc {}
    foreach c {0 1 2} { lappend sc [expr {$c in $cols ? [lindex {a b c} $c] : "NULL"}] }
    return "SELECT [join $sc {, }], COUNT(*), SUM(v), GROUPING([join $names {, }]) FROM t"
}
proc run {sql} { lsort [dict get [q $sql] rows] }
set ::maskCols {0 1} ; check "ROLLUP(a, b)" [run "[sel {0 1}] GROUP BY ROLLUP (a, b)"] [ref {{0 1} {0} {}}]
set ::maskCols {0 1 2} ; check "ROLLUP(a, b, c)" [run "[sel {0 1 2}] GROUP BY ROLLUP (a, b, c)"] [ref {{0 1 2} {0 1} {0} {}}]
set ::maskCols {0 1} ; check "CUBE(a, b)" [run "[sel {0 1}] GROUP BY CUBE (a, b)"] [ref {{0 1} {0} {1} {}}]
set ::maskCols {0 1 2} ; check "CUBE(a, b, c)" [run "[sel {0 1 2}] GROUP BY CUBE (a, b, c)"] [ref {{0 1 2} {0 1} {0 2} {0} {1 2} {1} {2} {}}]
set ::maskCols {0 1 2} ; check "GROUPING SETS" [run "[sel {0 1 2}] GROUP BY GROUPING SETS ((a, b), (c), ())"] [ref {{0 1} {2} {}}]
set ::maskCols {0 1} ; check "GROUPING SETS plain items" [run "[sel {0 1}] GROUP BY GROUPING SETS (a, b)"] [ref {{0} {1}}]
set tot 0 ; foreach r $rows { incr tot [lindex $r 3] }
check "GROUP BY ()" [dict get [q "SELECT COUNT(*), SUM(v) FROM t GROUP BY ()"] rows] [list [list [llength $rows] $tot]]
set ::maskCols {0 1 2} ; check "a, ROLLUP(b, c)" [run "[sel {0 1 2}] GROUP BY a, ROLLUP (b, c)"] [ref {{0 1 2} {0 1} {0}}]
set ::maskCols {0 1} ; check "ROLLUP(a), ROLLUP(b)" [run "[sel {0 1}] GROUP BY ROLLUP (a), ROLLUP (b)"] [ref {{0 1} {0} {1} {}}]
set ::maskCols {0 1 2} ; check "ROLLUP((a, b), c)" [run "[sel {0 1 2}] GROUP BY ROLLUP ((a, b), c)"] [ref {{0 1 2} {0 1} {}}]
set ::maskCols {0 1 2} ; check "GROUPING SETS with ROLLUP inside" [run "[sel {0 1 2}] GROUP BY GROUPING SETS (ROLLUP (a, b), (c))"] [ref {{0 1} {0} {} {2}}]
set ::maskCols {0 2} ; check "CUBE(a), c" [run "[sel {0 2}] GROUP BY CUBE (a), c"] [ref {{0 2} {2}}]
set want {} ; foreach r [ref {{0 1} {0} {}}] { lappend want [list [lindex $r 0] [lindex $r 1] [lindex $r 3] [lindex $r 4]] }
check "positions"         [run "SELECT a, b, COUNT(*), SUM(v) FROM t GROUP BY ROLLUP (1, 2)"] [lsort $want]
# HAVING and ordering
set ::maskCols {0 1}
set want {} ; foreach r [ref {{0 1} {0} {}}] { if {[lindex $r 3] > 8} { lappend want $r } }
set ::maskCols {0 1} ; check "HAVING on an aggregate" [run "[sel {0 1}] GROUP BY ROLLUP (a, b) HAVING COUNT(*) > 8"] [lsort $want]
check "HAVING GROUPING" [run "[sel {0 1}] GROUP BY ROLLUP (a, b) HAVING GROUPING(a) = 1"] [ref {{}}]
check "GROUPING as a label" [dict get [q "SELECT CASE WHEN GROUPING(a) = 1 THEN 'ALL' ELSE a END AS who, SUM(v) FROM t GROUP BY ROLLUP (a) ORDER BY 1"] rows] [dict get [q "SELECT who, s FROM (SELECT a AS who, SUM(v) AS s FROM t GROUP BY a UNION ALL SELECT 'ALL', SUM(v) FROM t) u ORDER BY 1"] rows]
set r [dict get [q "SELECT a, SUM(v) AS s FROM t GROUP BY ROLLUP (a) ORDER BY a NULLS LAST"] rows]
check "ORDER BY the output column, NULLS LAST" [lindex [lindex $r end] 0] NULL
check "LIMIT over the result" [llength [dict get [q "SELECT a, b, COUNT(*) FROM t GROUP BY CUBE (a, b) ORDER BY 3 DESC LIMIT 4"] rows]] 4
check "alias in GROUP BY" [run "SELECT a AS grp, SUM(v), GROUPING(a) FROM t GROUP BY ROLLUP (grp)"] [lsort [dict get [q "SELECT a, SUM(v), 0 FROM t GROUP BY a UNION ALL SELECT NULL, SUM(v), 1 FROM t"] rows]]
check "expression as a group key" [run "SELECT c + 1, SUM(v), GROUPING(c + 1) FROM t GROUP BY ROLLUP (c + 1)"] [lsort [dict get [q "SELECT c + 1, SUM(v), 0 FROM t GROUP BY c + 1 UNION ALL SELECT NULL, SUM(v), 1 FROM t"] rows]]
check "expression over a nulled column" [run "SELECT a || '!', SUM(v) FROM t GROUP BY ROLLUP (a)"] [lsort [dict get [q "SELECT a || '!', SUM(v) FROM t GROUP BY a UNION ALL SELECT NULL, SUM(v) FROM t"] rows]]
check "DISTINCT over the union" [llength [dict get [q "SELECT DISTINCT a FROM t GROUP BY ROLLUP (a, b)"] rows]] 4
check "empty table: grand total still one row" [dict get [q "SELECT a, COUNT(*) FROM t WHERE c > 99 GROUP BY ROLLUP (a)"] rows] {{NULL 0}}
check "WHERE applies to every set" [run "SELECT a, COUNT(*) FROM t WHERE c = 1 GROUP BY ROLLUP (a)"] [lsort [dict get [q "SELECT a, COUNT(*) FROM t WHERE c = 1 GROUP BY a UNION ALL SELECT NULL, COUNT(*) FROM t WHERE c = 1"] rows]]
check "in a subquery" [dict get [q "SELECT COUNT(*) FROM (SELECT a, b, COUNT(*) FROM t GROUP BY CUBE (a, b)) x"] rows] [llength [ref {{0 1} {0} {1} {}}]]
check "a column named like a keyword" [string match "*" [err "CREATE TABLE r (rollup INT)"]] 1
q "INSERT INTO r VALUES (1), (1), (2)"
check "plain column called rollup" [dict get [q "SELECT rollup, COUNT(*) FROM r GROUP BY rollup ORDER BY rollup"] rows] {{1 2} {2 1}}
# errors
check "SELECT * is refused" [string match "*SELECT * cannot be used*" [err "SELECT * FROM t GROUP BY ROLLUP (a)"]] 1
check "GROUPING of a non-key" [string match "*GROUPING() takes grouping expressions*" [err "SELECT GROUPING(v) FROM t GROUP BY ROLLUP (a)"]] 1
check "ungrouped column" [string match "*must appear in the GROUP BY*" [err "SELECT v FROM t GROUP BY ROLLUP (a)"]] 1
check "position out of range" [string match "*out of range*" [err "SELECT a FROM t GROUP BY ROLLUP (5)"]] 1
check "ORDER BY something that is not an output column" [err "SELECT a FROM t GROUP BY ROLLUP (a) ORDER BY v"] [err "SELECT a FROM t GROUP BY ROLLUP (a) ORDER BY v"]
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "grouping sets: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
