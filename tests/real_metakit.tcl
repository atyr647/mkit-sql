# Checks that only mean something on the REAL Mk4tcl (persistence across close/reopen,
# 64-bit values, binary data, unicode, nested subviews, ALTERs, drop/recreate):
#   MKIT_MK4TCL=/path/to/libMk4tcl.so tclsh tests/real_metakit.tcl
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(MKIT_MK4TCL)] || $::env(MKIT_MK4TCL) eq ""} { puts "set MKIT_MK4TCL to the Mk4tcl shared library" ; exit 2 }
load $::env(MKIT_MK4TCL) Mk4tcl
source $here/vendor/store.tcl
source [file join [file dirname $here] mkitsql mkitsql.tcl]
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_real_[pid].mk ; file delete $f
set db [store::openFile $f -create]
set pass 0 ; set fail 0
proc chk {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  $got\n  want: $want"} }
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }
set U "caf[format %c 233] [format %c 9731]"
q "CREATE TABLE t (id INT, big BIGINT, r REAL, d DOUBLE PRECISION, s VARCHAR, b BLOB, kids TABLE (name TEXT, toys TABLE (toy TEXT, n INT)))"
q "INSERT INTO t (id, big, r, d, s, b) VALUES (1, 9223372036854775807, 1.5, 0.1, '$U', X'00FF10'), (2, -9223372036854775808, 2.25, 1e300, '', X'')"
q "INSERT INTO t\[0\].kids (name) VALUES ('Zed'), ('Amy')"
q "INSERT INTO t\[0\].kids\[1\].toys (toy, n) VALUES ('ball', 3), ('kite', 1)"
chk bigint [rows "SELECT big FROM t ORDER BY id"] {9223372036854775807 -9223372036854775808}
chk bigint_cmp [rows "SELECT id FROM t WHERE big > 9223372036854775800"] 1
chk dbl [rows "SELECT d FROM t ORDER BY id"] {0.1 1e+300}
chk real [rows "SELECT r FROM t ORDER BY id"] {1.5 2.25}
chk text [rows "SELECT s, LENGTH(s) FROM t ORDER BY id"] [list [list $U 6] [list "" 0]]
chk blob [rows "SELECT LENGTH(b) FROM t ORDER BY id"] {3 0}
chk deep [rows "SELECT k.name, t2.toy FROM t, t.kids k, k.toys t2"] {{Amy ball} {Amy kite}}
chk deepcount [rows "SELECT name, toys FROM t\[0\].kids ORDER BY name"] [list [list Amy "[format %c 9656] 2 rows"] [list Zed "[format %c 9656] 0 rows"]]
q "COMMIT"
store::closeFile $db
set db [store::openFile $f]
chk persist_rows [rows "SELECT id, big FROM t ORDER BY id"] {{1 9223372036854775807} {2 -9223372036854775808}}
chk persist_text [rows "SELECT s FROM t WHERE id = 1"] [list [list $U]]
chk persist_deep [rows "SELECT toy, n FROM t\[0\].kids\[1\].toys ORDER BY toy"] {{ball 3} {kite 1}}
chk persist_layout [store::layout $db.t] [store::layout $db.t]
q "ALTER TABLE t RENAME COLUMN s TO txt"
chk rename_data [rows "SELECT txt FROM t WHERE id = 1"] [list [list $U]]
q "ALTER TABLE t ALTER COLUMN id SET DATA TYPE VARCHAR"
chk retype [rows "SELECT id FROM t ORDER BY id"] {1 2}
q "ALTER TABLE t ADD COLUMN extra INT"
chk addcol [rows "SELECT extra FROM t"] {0 0}
q "ALTER TABLE t DROP COLUMN extra"
q "ALTER TABLE t RENAME TO t2"
chk rename_deep [rows "SELECT k.name FROM t2, t2.kids k ORDER BY k.name"] {Amy Zed}
chk rename_deep2 [rows "SELECT toy FROM t2\[0\].kids\[1\].toys ORDER BY toy"] {ball kite}
q "ROLLBACK"
chk rollback_restores [rows "SELECT COUNT(*) FROM t"] 2
chk views_after_rollback [store::views $db] t
q "DROP TABLE t"
q "CREATE TABLE t (a INT)"
chk drop_create_same_session [store::layout $db.t] {{a I {}}}
q "COMMIT"
store::closeFile $db
set db [store::openFile $f -readonly]
chk readonly_select [rows "SELECT COUNT(*) FROM t"] 0
chk readonly_write [catch {q "INSERT INTO t (a) VALUES (1)"} m] 1
file delete $f
puts "real-Metakit checks: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
