# Pushing conditions into Metakit (mk::select) must only ever NARROW a scan.  Random predicates over every column type,
# edge values, mixed int / real constants, IN lists, BETWEEN, strict and inclusive bounds, several conjuncts, ORs and NOTs
# (which are not pushed), and data-changing statements: each is run with pushdown on and off and the results must be
# identical.  The counter proves the shortcut really ran.
#   tclsh tests/pushdown.tcl [rounds] [seed]
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set rounds [expr {$argc > 0 ? [lindex $argv 0] : 600}]
expr {srand([expr {$argc > 1 ? [lindex $argv 1] : 1}])}
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_pd_[pid].mk
file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }

q "CREATE TABLE t (id INT, big BIGINT, d DOUBLE PRECISION, s TEXT, n TEXT, g INT)"
set ints {0 1 -1 2 7 -7 100 2147483646 -2147483647 2147483647 -2147483648 5 5 6 6}
set bigs {0 1 -1 4294967296 -4294967296 4611686018427387904 -4611686018427387904 9223372036854775807 -9223372036854775808 123 123}
set dbls {0.0 0.1 -0.1 0.5 1.0 2.5 -2.5 1e-300 1e300 -1e300 100.25 3.0 3.0 7.0 -7.0}
set strs [list "" a A b ab abc "a b" "x'y" [format %c 233] "[format %c 26085][format %c 26412]" Zed zed 007 7 7.0 -5 NULL " " "{x}" "a\\b"]
set vals {}
set id 0
for {set rep 0} {$rep < 60} {incr rep} {
    foreach i $ints b $bigs d [lrange $dbls 0 end] {
        incr id
        set s [lindex $strs [expr {($id * 7) % [llength $strs]}]]
        set n [lindex $strs [expr {($id * 3) % [llength $strs]}]]
        if {$b eq ""} { set b 0 } ; if {$d eq ""} { set d 0.0 }
        lappend vals [list $id [expr {$i}] $b $d $s $n [expr {$id % 9}]]
    }
}
foreach r $vals {
    lassign $r id i b d s n g
    mkitsql::db::appendRow $db.t {id big d s n g} [list $i $b $d $s $n $g]
}
q "UPDATE t SET id = _rowid"        ;# a unique id column
q "COMMIT"
set total [llength $vals]

proc lit {kind} {
    switch $kind {
        int  { return [lindex {0 1 -1 2 5 6 7 -7 100 2147483646 -2147483647 2147483647 -2147483648 2147483648 99999999999 3} [expr {int(rand()*16)}]] }
        big  { return [lindex {0 1 -1 123 4294967296 -4294967296 4611686018427387904 9223372036854775807 -9223372036854775808 9223372036854775806} [expr {int(rand()*10)}]] }
        real { return [lindex {0.0 0.1 -0.1 0.5 1.0 2.5 -2.5 100.25 3.0 7.0 -7.0 1e300 -1e300 1e-300 5.0 5.5 2147483647.0 0.30000000000000004} [expr {int(rand()*18)}]] }
        text { set s [lindex $::strs [expr {int(rand()*[llength $::strs])}]] ; return "'[string map {' ''} $s]'" }
    }
}
proc pred {} {
    set c [expr {int(rand()*9)}]
    set cols {id big d s n g}
    set col [lindex $cols [expr {int(rand()*6)}]]
    set op [lindex {= < <= > >= =} [expr {int(rand()*6)}]]
    switch $col {
        id - g { set k [lindex {int int int real text} [expr {int(rand()*5)}]] }
        big    { set k [lindex {int big big real text} [expr {int(rand()*5)}]] }
        d      { set k [lindex {int real real real text} [expr {int(rand()*5)}]] }
        default { set k [lindex {text text text int real} [expr {int(rand()*5)}]] }
    }
    switch $c {
        0 - 1 - 2 { return "$col $op [lit $k]" }
        3 { return "[lit $k] $op $col" }
        4 { set a [lit $k] ; set b [lit $k] ; return "$col BETWEEN $a AND $b" }
        5 { set l {} ; for {set i 0} {$i < 1 + int(rand()*4)} {incr i} { lappend l [lit $k] } ; return "$col IN ([join $l {, }])" }
        6 { return "NOT ($col $op [lit $k])" }
        7 { return "($col $op [lit $k] OR $col $op [lit $k])" }
        default { return "$col <> [lit $k]" }
    }
}
proc both {sql} {
    set mkitsql::pushdown 1
    set a [expr {[catch {rows $sql} r] ? "ERR $r" : $r}]
    set mkitsql::pushdown 0
    set b [expr {[catch {rows $sql} r] ? "ERR $r" : $r}]
    set mkitsql::pushdown 1
    return [list $a $b]
}
set mkitsql::pushMin 0
set before $mkitsql::pushScans
set nonempty 0
for {set r 0} {$r < $rounds} {incr r} {
    set n [expr {1 + int(rand()*3)}]
    set w {}
    for {set i 0} {$i < $n} {incr i} { lappend w [pred] }
    set where [join $w " AND "]
    foreach shape [list "SELECT id FROM t WHERE $where ORDER BY id" "SELECT COUNT(*), SUM(g), MAX(s) FROM t WHERE $where" "SELECT t.id FROM t JOIN (SELECT 3 AS g) x ON t.g = x.g WHERE $where ORDER BY t.id"] {
        lassign [both $shape] a b
        check "pushdown == full scan: $shape" $a $b
        if {[string match "SELECT id*" $shape] && [llength $a] > 0 && $a ne "ERR"} { incr nonempty }
    }
}
check shortcut_really_used [expr {$mkitsql::pushScans - $before > $rounds}] 1
check some_predicates_matched [expr {$nonempty > $rounds / 10}] 1

# data-changing statements use it too
foreach {label sql} {
    del1 {DELETE FROM t WHERE id = 100}
    del2 {DELETE FROM t WHERE s = 'a' AND g = 3}
    del3 {DELETE FROM t WHERE d BETWEEN 0.5 AND 3.0 AND big > 0}
    upd1 {UPDATE t SET s = s || '!' WHERE id BETWEEN 10 AND 40}
    upd2 {UPDATE t SET g = g + 1 WHERE n IN ('a', 'b', 'abc') AND id > 50}
    upd3 {UPDATE t SET d = d * 2 WHERE big = 4294967296}
} {
    set res {}
    foreach pd {0 1} {
        q "ROLLBACK"
        set mkitsql::pushdown $pd
        set cnt [dict get [q $sql] affected]
        lappend res [list $cnt [rows "SELECT id, big, d, s, n, g FROM t ORDER BY id"]]
    }
    set mkitsql::pushdown 1
    q "ROLLBACK"
    if {[lindex $res 1] ne [lindex $res 0]} {
        set A [lindex $res 0 1] ; set B [lindex $res 1 1]
        for {set i 0} {$i < [llength $A]} {incr i} { if {[lindex $A $i] ne [lindex $B $i]} { puts "first difference at row $i: scan=[lindex $A $i] pushdown=[lindex $B $i]" ; break } }
    }
    check "dml $label: pushdown == full scan" [lindex $res 1] [lindex $res 0]
    check "dml $label: touched something" [expr {[lindex $res 0 0] > 0}] 1
}
# the pushed filter must not be applied twice or lost on NULL-extended joins
q "ROLLBACK"
check outer_join_not_pushed_wrongly [both "SELECT COUNT(*) FROM t a LEFT JOIN t b ON a.id = b.id AND b.g = 3 WHERE a.g = 4"] [list [rows "SELECT COUNT(*) FROM t a LEFT JOIN t b ON a.id = b.id AND b.g = 3 WHERE a.g = 4"] [rows "SELECT COUNT(*) FROM t a LEFT JOIN t b ON a.id = b.id AND b.g = 3 WHERE a.g = 4"]]
lassign [both "SELECT a.id, b.id FROM t a LEFT JOIN t b ON a.id = b.id + 1 AND b.g = 3 WHERE a.id < 40 ORDER BY 1, 2"] x y
check left_join_filter_on_nullable_side $x $y
lassign [both "SELECT a.id FROM t a RIGHT JOIN t b ON a.id = b.id AND a.g = 3 WHERE b.id < 30 ORDER BY 1"] x y
check right_join_filter $x $y
lassign [both "SELECT id FROM t WHERE g = 2 AND id IN (SELECT id FROM t WHERE g = 2 AND s = 'a') ORDER BY id"] x y
check subquery_inner_pushdown $x $y
lassign [both "SELECT id, (SELECT COUNT(*) FROM t y WHERE y.g = x.g AND y.s = 'a') FROM t x WHERE x.id < 20 ORDER BY id"] x y
check correlated_with_static_pushdown $x $y

mkitsql::db::closeFile $db
file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
