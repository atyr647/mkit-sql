# Derived tables and CTEs may have two columns of the same name; only a reference to that name is an error.   tclsh tests/dupcols.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_dc2_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc q {sql} { mkitsql::run $sql $::db }
proc err {sql} { if {[catch {q $sql} e]} { return $e } ; return "" }
q "CREATE TABLE a (id INT, x TEXT)" ; q "CREATE TABLE b (id INT, y TEXT)"
q "INSERT INTO a VALUES (1,'a1'),(2,'a2')" ; q "INSERT INTO b VALUES (1,'b1'),(3,'b3')"
set r [q "SELECT * FROM (SELECT a.id, b.id FROM a JOIN b ON a.id = b.id) t"]
check "star over a derived table with two id columns: names" [dict get $r cols] {id id}
check "... rows" [dict get $r rows] {{1 1}}
set r [q "SELECT * FROM (SELECT * FROM a JOIN b ON a.id = b.id) t"]
check "SELECT * of a join inside a subquery" [list [dict get $r cols] [dict get $r rows]] [list {id x id y} {{1 a1 1 b1}}]
set r [q "WITH c AS (SELECT * FROM a JOIN b ON a.id = b.id) SELECT * FROM c"]
check "CTE" [list [dict get $r cols] [dict get $r rows]] [list {id x id y} {{1 a1 1 b1}}]
check "other columns stay usable" [dict get [q "WITH c AS (SELECT * FROM a JOIN b ON a.id = b.id) SELECT x, y FROM c"] rows] {{a1 b1}}
set r [q "WITH c AS (SELECT * FROM a JOIN b ON a.id = b.id) SELECT * FROM (SELECT * FROM c) d"]
check "two levels" [list [dict get $r cols] [dict get $r rows]] [list {id x id y} {{1 a1 1 b1}}]
check "qualified star" [dict get [q "SELECT t.* FROM (SELECT a.id, b.id FROM a JOIN b ON a.id = b.id) t"] rows] {{1 1}}
check "COUNT(*)" [dict get [q "SELECT COUNT(*) FROM (SELECT a.id, b.id FROM a, b) t"] rows] 4
check "reference to the duplicated name" [string match "*ambiguous*Give them different names*" [err "SELECT t.id FROM (SELECT a.id, b.id FROM a JOIN b ON a.id = b.id) t"]] 1
check "unqualified reference" [string match "*ambiguous*" [err "SELECT id FROM (SELECT a.id, b.id FROM a JOIN b ON a.id = b.id) t"]] 1
check "WHERE on the duplicated name" [string match "*ambiguous*" [err "SELECT * FROM (SELECT a.id, b.id FROM a JOIN b ON a.id = b.id) t WHERE id = 1"]] 1
check "case-insensitive" [string match "*ambiguous*" [err "SELECT ID FROM (SELECT a.id, b.id FROM a JOIN b ON a.id = b.id) t"]] 1
check "an explicit column list must still be distinct" [string match "*two columns named*" [err "SELECT * FROM (SELECT 1, 2) t(p, p)"]] 1
check "a column list renames them" [dict get [q "SELECT p, q FROM (SELECT a.id, b.id FROM a JOIN b ON a.id = b.id) t(p, q)"] rows] {{1 1}}
check "aliases in the subquery" [dict get [q "SELECT aid, bid FROM (SELECT a.id AS aid, b.id AS bid FROM a JOIN b ON a.id = b.id) t"] rows] {{1 1}}
check "INSERT ... SELECT * from a duplicated-name subquery" [dict get [q "CREATE TABLE both AS SELECT * FROM (SELECT a.id AS p, b.id AS q FROM a JOIN b ON a.id = b.id) t"] affected] 1
check "join of two derived tables with the same columns" [dict get [q "SELECT COUNT(*) FROM (SELECT a.id, b.id FROM a, b) s JOIN (SELECT a.id, b.id FROM a, b) t ON 1 = 1"] rows] 16
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "duplicate column names: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
