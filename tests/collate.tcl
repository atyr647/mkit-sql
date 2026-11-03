# COLLATE BINARY / NOCASE: comparisons, IN, BETWEEN, LIKE, ORDER BY, GROUP BY, select list, errors.   tclsh tests/collate.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_co_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }
proc err {sql} { if {[catch {q $sql} e]} { return $e } ; return "" }
q "CREATE TABLE w (id INT, s TEXT)"
q "INSERT INTO w VALUES (1,'apple'),(2,'Apple'),(3,'BANANA'),(4,'banana'),(5,'Cherry'),(6,'avocado')"
check "= is case-sensitive by default" [rows "SELECT id FROM w WHERE s = 'apple' ORDER BY id"] {1}
check "= COLLATE NOCASE" [rows "SELECT id FROM w WHERE s COLLATE NOCASE = 'APPLE' ORDER BY id"] {1 2}
check "on the right side" [rows "SELECT id FROM w WHERE 'APPLE' = s COLLATE NOCASE ORDER BY id"] {1 2}
check "<> " [rows "SELECT id FROM w WHERE s COLLATE NOCASE <> 'apple' ORDER BY id"] {3 4 5 6}
check "< (case-insensitive order)" [rows "SELECT id FROM w WHERE s COLLATE NOCASE < 'b' ORDER BY id"] {1 2 6}
check "BINARY is the default" [rows "SELECT id FROM w WHERE s COLLATE BINARY = 'apple'"] {1}
check "IN" [rows "SELECT id FROM w WHERE s COLLATE NOCASE IN ('APPLE', 'cherry') ORDER BY id"] {1 2 5}
check "NOT IN" [rows "SELECT id FROM w WHERE s COLLATE NOCASE NOT IN ('APPLE', 'cherry') ORDER BY id"] {3 4 6}
check "BETWEEN" [rows "SELECT id FROM w WHERE s COLLATE NOCASE BETWEEN 'A' AND 'B' ORDER BY id"] {1 2 6}
check "LIKE becomes case-insensitive" [rows "SELECT id FROM w WHERE s COLLATE NOCASE LIKE 'AP%' ORDER BY id"] {1 2}
check "LIKE is case-sensitive otherwise" [rows "SELECT id FROM w WHERE s LIKE 'AP%' ORDER BY id"] {}
check "ORDER BY NOCASE" [rows "SELECT s FROM w ORDER BY s COLLATE NOCASE, id"] {apple Apple avocado BANANA banana Cherry}
check "ORDER BY binary" [rows "SELECT s FROM w ORDER BY s, id"] {Apple BANANA Cherry apple avocado banana}
check "ORDER BY NOCASE DESC" [rows "SELECT id FROM w ORDER BY s COLLATE NOCASE DESC, id"] {5 3 4 6 1 2}
check "GROUP BY NOCASE" [rows "SELECT s COLLATE NOCASE, COUNT(*) FROM w GROUP BY s COLLATE NOCASE ORDER BY 2 DESC, 1"] {{Apple 2} {BANANA 2} {Cherry 1} {avocado 1}}
check "GROUP BY NOCASE: select the column" [llength [rows "SELECT s, COUNT(*) FROM w GROUP BY s COLLATE NOCASE"]] 4
check "HAVING with a grouped collated column" [rows "SELECT s, COUNT(*) FROM w GROUP BY s COLLATE NOCASE HAVING COUNT(*) > 1 ORDER BY 1"] {{Apple 2} {BANANA 2}}
check "select list: nothing changes" [rows "SELECT s COLLATE NOCASE FROM w WHERE id = 3"] {BANANA}
check "JOIN ON" [rows "SELECT a.id, b.id FROM w a JOIN w b ON a.s COLLATE NOCASE = b.s AND a.id < b.id ORDER BY 1"] {{1 2} {3 4}}
check "window ORDER BY" [rows "SELECT id, ROW_NUMBER() OVER (ORDER BY s COLLATE NOCASE, id) FROM w ORDER BY id"] {{1 1} {2 2} {3 4} {4 5} {5 6} {6 3}}
check "CASE-INSENSITIVE alias" [rows "SELECT id FROM w WHERE s COLLATE CASE_INSENSITIVE = 'BANANA' ORDER BY id"] {3 4}
check "C = binary" [rows "SELECT id FROM w WHERE s COLLATE \"C\" = 'apple'"] {1}
check "two sides, one collated" [rows "SELECT COUNT(*) FROM w WHERE s = 'x' COLLATE NOCASE"] 0
check "unknown collation" [string match "*Unknown collation 'fr_FR'*supported*" [err "SELECT * FROM w WHERE s COLLATE fr_FR = 'a'"]] 1
check "different collations" [string match "*different collations*" [err "SELECT * FROM w WHERE s COLLATE NOCASE = 'a' COLLATE BINARY"]] 1
check "unsupported place" [string match "*COLLATE is only supported*" [err "SELECT UPPER(s COLLATE NOCASE) FROM w"]] 1
check "IS DISTINCT FROM is unsupported" [string match "*COLLATE is only supported*" [err "SELECT * FROM w WHERE s COLLATE NOCASE IS DISTINCT FROM 'a'"]] 1
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "collate: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
