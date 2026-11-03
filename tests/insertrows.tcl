# ::mkitsql::insertRows gives exactly what INSERT ... VALUES gives (conversions, range errors, NULL handling, all-or-nothing, transactions).   tclsh tests/insertrows.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_ir_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" } }
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }
proc err {script} { if {[catch {uplevel 1 $script} e]} { return $e } ; return "" }
q "CREATE TABLE a (id INT, big BIGINT, d DOUBLE PRECISION, s TEXT, b BLOB)"
q "CREATE TABLE b (id INT, big BIGINT, d DOUBLE PRECISION, s TEXT, b BLOB)"
set data {{1 9223372036854775807 0.5 hello abc} {2 -5 2 {with space} {}} {3 7 1000.5 {quote ' and "dq" {brace}} x} {4 0 -0.0 cafe y} {5 12 3 {#hash first} z}}
mkitsql::insertRows $db a {} $data
foreach r $data {
    lassign $r id big d s bl
    set lit "'[string map {' ''} $s]'"
    q "INSERT INTO b VALUES ($id, $big, $d, $lit, '[string map {' ''} $bl]')"
}
mkitsql::insertRows $db a {id s} [list [list 50 "caf[format %c 233] [format %c 26085]"]]
check "non-ASCII text" [rows "SELECT LENGTH(s) FROM a WHERE id = 50"] 6
q "DELETE FROM a WHERE id = 50"
check "same rows as INSERT ... VALUES" [rows "SELECT * FROM a ORDER BY id"] [rows "SELECT * FROM b ORDER BY id"]
check "result" [dict get [mkitsql::insertRows $db a {id s} {{10 x} {11 y}}] affected] 2
check "column subset: others get the default" [rows "SELECT id, big, s FROM a WHERE id >= 10 ORDER BY id"] {{10 0 x} {11 0 y}}
check "qualified table name" [dict get [mkitsql::insertRows $db [lindex [mkitsql::db::tags] 0].a {id} {{12}}] affected] 1
check "NULL token" [rows "SELECT s FROM a WHERE id = 13"] {}
mkitsql::insertRows $db a {id s} {{13 NIL}} -null NIL
check "NULL is stored as the default" [rows "SELECT s FROM a WHERE id = 13"] [list [list ""]]
# subview targets and SQL-style names
q "CREATE TABLE sv (id INT, kids TABLE (name TEXT, n INT))"
q "INSERT INTO sv (id) VALUES (1), (2)"
mkitsql::insertRows $db {sv[1].kids} {name n} {{a 1} {b 2}}
check "subview target" [rows "SELECT name, n FROM sv\[1\].kids ORDER BY n"] {{a 1} {b 2}}
check "a table name that is not one" [string match "*is not a table name*" [err {mkitsql::insertRows $db {a; DROP TABLE b} {id} {{1}}}]] 1
check "a table name with a WHERE" [string match "*is not a table name*" [err {mkitsql::insertRows $db {a WHERE 1=1} {id} {{1}}}]] 1
check "an unknown option" [string match "*unknown option*" [err {mkitsql::insertRows $db a {id} {{1}} -nul x}]] 1
check "the sentinel as a real null token" [dict get [mkitsql::insertRows $db a {id s} [list [list 90 "x[format %c 64977]none"]] -null "x[format %c 64977]none"] affected] 1
# errors, all-or-nothing
set before [rows "SELECT COUNT(*) FROM a"]
check "range error" [string match "*BIGINT*" [err {mkitsql::insertRows $db a {id} {{20} {99999999999}}}]] 1
check "nothing was inserted" [rows "SELECT COUNT(*) FROM a"] $before
check "not a number" [string match "*not a whole number*" [err {mkitsql::insertRows $db a {id} {{abc}}}]] 1
check "wrong width" [string match "*Row 2 has 1 value*" [err {mkitsql::insertRows $db a {id s} {{1 x} {2}}}]] 1
check "unknown column" [string match "*Unknown column 'nope'*" [err {mkitsql::insertRows $db a {nope} {{1}}}]] 1
check "column twice" [string match "*listed twice*" [err {mkitsql::insertRows $db a {id id} {{1 2}}}]] 1
check "unknown table" [err {mkitsql::insertRows $db nosuch {id} {{1}}}] [err {q "INSERT INTO nosuch (id) VALUES (1)"}]
check "reserved NULL character refused" [string match "*U+FDD0*" [err {mkitsql::insertRows $db a {s} [list [list "x[format %c 64976]y"]]}]] 1
# transactions: rolls back like INSERT
q COMMIT
mkitsql::insertRows $db a {id} {{100} {101}}
q ROLLBACK
check "ROLLBACK undoes it" [rows "SELECT COUNT(*) FROM a WHERE id >= 100"] 0
mkitsql::insertRows $db a {id} {{100} {101}}
q COMMIT
check "COMMIT keeps it" [rows "SELECT COUNT(*) FROM a WHERE id >= 100"] 2
# a statement cannot start inside another
check "an empty row list is fine" [dict get [mkitsql::insertRows $db a {id} {}] affected] 0
# bigger load and the speed it is for
set big {} ; for {set i 0} {$i < 5000} {incr i} { lappend big [list [expr {1000 + $i}] $i [expr {$i / 4.0}] "n$i" x] }
set t0 [clock milliseconds] ; mkitsql::insertRows $db a {} $big ; set ms [expr {[clock milliseconds] - $t0}]
check "5000 rows" [rows "SELECT COUNT(*) FROM a WHERE id >= 1000"] 5000
puts "  (5000 rows in $ms ms)"
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "insertRows: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
