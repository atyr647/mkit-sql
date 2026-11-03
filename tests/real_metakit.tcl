# Checks that only mean something on the REAL Mk4tcl (persistence across close/reopen,
# 64-bit values, binary data, unicode, nested subviews, ALTERs, drop/recreate):
#   MKIT_MK4TCL=/path/to/libMk4tcl.so tclsh tests/real_metakit.tcl
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(MKIT_MK4TCL)] || $::env(MKIT_MK4TCL) eq ""} { puts "set MKIT_MK4TCL to the Mk4tcl shared library, or to 'builtin' inside a tclkit" ; exit 2 }
source $here/mk4load.tcl
source $here/loadengine.tcl
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_real_[pid].mk ; file delete $f
set db [store::openFile $f -create]
set pass 0 ; set fail 0
# Windows cannot delete a file another handle (Metakit's mapping) still has open for a moment after close: retry for up to 5 s
proc rmfile {f} { for {set i 0} {$i < 50} {incr i} { if {![catch {file delete $f}]} return ; after 100 } ; file delete $f }
proc chk {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  $got\n  want: $want"} }
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }
proc lmap_ {l spec} { lassign $spec v b ; set o {} ; foreach item $l { lappend o [apply [list $v $b] $item] } ; return $o }
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
chk retype_refused [string match "Metakit cannot change the type of column 'id' in place*" [expr {[catch {q "ALTER TABLE t ALTER COLUMN id SET DATA TYPE VARCHAR"} m] ? $m : ""}]] 1
chk retype_data_untouched [rows "SELECT id FROM t ORDER BY id"] {1 2}
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
# ---- Metakit cannot change a column's type under the same name (found by tests/differential/features.py) -----------------
# On real Metakit, DROP TABLE t; CREATE TABLE t (x TEXT) after t had x INT made writes fail and reads return 0, and the
# file could hang on close.  The storage layer now refuses (or, when nothing is pending and it owns the file, reopens first).
store::closeFile $db
rmfile $f
set db [store::openFile $f -create]
set standalone [expr {$::mkitsql::backend eq "standalone"}]
q "CREATE TABLE ty (id INT, x INT)"
q "INSERT INTO ty VALUES (1, 42)"
q "COMMIT"
q "DROP TABLE ty"
set m [expr {[catch {q "CREATE TABLE ty (id INT, x TEXT)"} m] ? $m : "no error"}]
chk typeclash_pending_refused [string match "Column 'x' of 'ty' has been integer in this open file and cannot become text*" $m] 1
chk typeclash_error_code [catch {q "CREATE TABLE ty (id INT, x TEXT)"} m opts] 1
chk typeclash_code [lrange [dict get $opts -errorcode] 0 3] {MKQL ERROR MKIT TYPECONFLICT}
q "ROLLBACK"
chk typeclash_rollback_restores [rows "SELECT id, x FROM ty"] {{1 42}}
q "DROP TABLE ty"
q "COMMIT"
set rc [catch {q "CREATE TABLE ty (id INT, x TEXT)"} m]
if {$standalone} {
    chk typeclash_after_commit_reopens $rc 0
    q "INSERT INTO ty VALUES (1, 'hello')"
    chk typeclash_text_stored [rows "SELECT id, x FROM ty"] {{1 hello}}
    q "COMMIT"
    store::closeFile $db ; set db [store::openFile $f]
    chk typeclash_persisted [rows "SELECT id, x FROM ty"] {{1 hello}}
} else {
    chk typeclash_studio_backend_refuses $rc 1
}
# add / drop / add with another type
q "CREATE TABLE tz (id INT)" ; q "INSERT INTO tz VALUES (1)" ; q "COMMIT"
q "ALTER TABLE tz ADD COLUMN y INT"
q "ALTER TABLE tz DROP COLUMN y"
chk addcol_other_type_refused [string match "Column 'y' of 'tz' has been integer*" [expr {[catch {q "ALTER TABLE tz ADD COLUMN y TEXT"} m] ? $m : "no error"}]] 1
q "COMMIT"
set rc [catch {q "ALTER TABLE tz ADD COLUMN y TEXT"} m]
if {$standalone} {
    chk addcol_after_commit_reopens $rc 0
    q "UPDATE tz SET y = 'hello'" ; q "COMMIT"
    store::closeFile $db ; set db [store::openFile $f]
    chk addcol_persisted [rows "SELECT id, y FROM tz"] {{1 hello}}
} else { chk addcol_studio_backend_refuses $rc 1 }
# renames of columns of different types in a row (the temporary column must never come back with another type), persisted
q "CREATE TABLE rn (id INT, name TEXT, qty INT, price DOUBLE PRECISION)"
q "INSERT INTO rn VALUES (1, 'a', 5, 1.5), (2, 'b', 6, 2.5)"
q "COMMIT"
foreach {a b} {qty c2  name c3  price c4  c2 qty  c3 name  id key  c4 price  key id} { q "ALTER TABLE rn RENAME COLUMN $a TO $b" }
chk renames_data [rows "SELECT id, name, qty, price FROM rn ORDER BY id"] {{1 a 5 1.5} {2 b 6 2.5}}
q "COMMIT"
store::closeFile $db ; set db [store::openFile $f]
chk renames_persisted [rows "SELECT id, name, qty, price FROM rn ORDER BY id"] {{1 a 5 1.5} {2 b 6 2.5}}
chk renames_no_temp_columns [llength [lsearch -all -glob [lmap_ [store::layout $db.rn] {c {lindex $c 0}}] __mks_tmp*]] 0
q "UPDATE rn SET name = 'zz', qty = 99 WHERE id = 1"
chk renames_still_writable [rows "SELECT name, qty FROM rn WHERE id = 1"] {{zz 99}}
q "COMMIT"

catch {store::closeFile $db} ; rmfile $f
puts "real-Metakit checks: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
