# NULL must be unforgeable.  Inside the engine NULL is the string  U+FDD0 + "NULL";  the engine keeps the
# invariant "no value contains U+FDD0", so no SQL text, parameter, stored value or function can ever
# produce it.  This test attacks that invariant from every direction.
#   tclsh tests/nullforge.tcl        (MKIT_MK4TCL as for the other tests)
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/budget.tcl
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_nf_[pid].mk
file delete $f
set db [store::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
proc run {sql {p {}} {n {}}} { mkitsql::run $sql $::db $p $n }
proc rows {sql {p {}} {n {}}} { dict get [run $sql $p $n] rows }
proc err {sql {p {}} {n {}}} { if {[catch {run $sql $p $n} m]} { return $m } ; return "(no error)" }
set M [format %c 64976]
set R [format %c 65533]
set N $mkitsql::N
check marker_is_noncharacter [scan $M %c] 64976
check sentinel_shape $N ${M}NULL

# --- SQL text -------------------------------------------------------------------------------------------
foreach {name sql} [list \
    in_literal "SELECT '${M}NULL'" \
    in_literal_pieces "SELECT '${M}' || 'NULL'" \
    in_ident "SELECT 1 AS ${M}x" \
    in_quoted_ident "SELECT 1 AS \"${M}x\"" \
    in_comment "SELECT 1 -- ${M}" \
    in_block_comment "SELECT 1 /* ${M} */"] {
    check text_$name [string match "*U+FDD0*reserved*" [err $sql]] 1
}
set code ""
catch {run "SELECT 1, '${M}'"} m opts
check text_errorcode [lrange [dict get $opts -errorcode] 0 3] {MKQL SYNTAX 11 1}

# --- parameters -----------------------------------------------------------------------------------------
check param_sentinel_text_rejected [string match "*Parameter #1 contains U+FDD0*" [err "SELECT ?" [list $N]]] 1
check param_marker_rejected [string match "*contains U+FDD0*" [err "SELECT ?" [list "a${M}b"]]] 1
check param_named_rejected [string match "*Parameter :n contains U+FDD0*" [err "SELECT :n" [list n $N]]] 1
check param_text_NULL [rows "SELECT ? IS NULL, ? IS NULL, ?" {NULL null {}}] {{0 0 {}}}
check param_null_positional [rows "SELECT ? IS NULL, ? IS NULL, ? IS NULL" {a b c} {2}] {{0 1 0}}
check param_null_named [rows "SELECT :a IS NULL, :b IS NULL" {a 1 b 2} {b}] {{0 1}}
check param_null_missing [string match "*does not have*" [err "SELECT ?" {a} {5}]] 1
run "CREATE TABLE pn (id INT, v TEXT)"
run "INSERT INTO pn VALUES (?, ?)" {1 x} {2}
check param_null_stored [rows "SELECT id, v, v IS NULL FROM pn"] {{1 {} 0}}   ;# stored NULL becomes empty text

# --- functions cannot build it ---------------------------------------------------------------------------
check chr_marker [string match "*reserved*" [err "SELECT CHR(64976)"]] 1
check chr_neighbour [rows "SELECT LENGTH(CHR(64975)), LENGTH(CHR(64977)), CHR(64977) IS NULL"] {{1 1 0}}
check blob_utf8_bytes [rows "SELECT CAST(X'EFB790' AS TEXT) IS NULL, LENGTH(CAST(X'EFB790' AS TEXT))"] {{0 3}}
check blob_cast_roundtrip [rows "SELECT (CAST(X'EFB790' AS TEXT) || 'NULL') IS NULL"] {0}

# --- stored data -----------------------------------------------------------------------------------------
# a file may contain anything; write the dangerous values straight through the storage layer
run "CREATE TABLE evil (id INT, t TEXT, b BLOB)"
foreach {id t} [list 1 ${M}NULL 2 "a${M}b" 3 ${M} 4 "${M}${M}NULL" 5 plain] {
    store::appendRow $db.evil {id t b} [list $id $t [binary format H* EFB790]]
}
check stored_not_null [rows "SELECT id FROM evil WHERE t IS NULL"] {}
check stored_count [rows "SELECT COUNT(*), COUNT(t) FROM evil"] {{5 5}}
check stored_cleaned [rows "SELECT t FROM evil ORDER BY id"] [list [list "${R}NULL"] [list "a${R}b"] [list "${R}"] [list "${R}${R}NULL"] [list plain]]
check stored_blob_bytes [rows "SELECT b IS NULL, LENGTH(b) FROM evil WHERE id = 5"] {{0 3}}
check stored_coalesce [rows "SELECT COALESCE(t, 'dflt') FROM evil WHERE id = 1"] [list [list "${R}NULL"]]
check stored_nullif [rows "SELECT NULLIF(t, 'x') IS NULL FROM evil WHERE id = 1"] {0}
check stored_group [rows "SELECT COUNT(*) FROM (SELECT t FROM evil GROUP BY t) g"] {5}
check stored_distinct [rows "SELECT COUNT(DISTINCT t) FROM evil"] {5}
check stored_order_nulls [rows "SELECT id FROM evil ORDER BY t NULLS LAST, id"] {2 5 3 1 4}
check stored_in_list [rows "SELECT id FROM evil WHERE t IN (SELECT t FROM evil)"] {1 2 3 4 5}
check stored_concat [rows "SELECT (t || 'x') IS NULL FROM evil WHERE id = 1"] {0}
check stored_substr [rows "SELECT SUBSTR(t, 2) IS NULL FROM evil WHERE id = 1"] {0}
# writes: a statement that read a cleaned value refuses to write (the clean copy must never be saved)
check write_refused_update [string match "Refusing to write*" [err "UPDATE evil SET t = t || '!' WHERE id = 1"]] 1
check write_refused_where [string match "Refusing to write*" [err "UPDATE evil SET id = 9 WHERE t = 'plain' OR t <> 'z'"]] 1
check write_refused_delete [string match "Refusing to write*" [err "DELETE FROM evil WHERE t <> 'zz'"]] 1
check write_refused_insert [string match "Refusing to write*" [err "INSERT INTO pn SELECT id, t FROM evil"]] 1
check write_refused_ctas [string match "Refusing to write*" [err "CREATE TABLE evil2 AS SELECT * FROM evil"]] 1
check write_untouched [mkitsql::db::hasView $db evil2] 0
check write_unchanged [llength [rows "SELECT id FROM evil"]] 5
# ... but a statement that does not read the damaged column can repair it
check write_repair [string match "*updated*" [dict get [run "UPDATE evil SET t = 'fixed' WHERE id = 1"] text]] 1
check write_repaired [rows "SELECT t FROM evil WHERE id = 1"] {fixed}
# table and column names from a file
store::createView $db "a${M}NULL" {{x I {}}}
check name_table_cleaned [rows "SELECT table_name FROM information_schema.tables WHERE table_name LIKE 'a%NULL'"] [list [list "a${R}NULL"]]
check name_table_not_null [rows "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IS NULL"] {0}
store::dropView $db "a${M}NULL"

# --- intervals use the same reserved prefix: text that looks like one is just text ----------------------
run "CREATE TABLE ivt (id INT, s TEXT)"
run "INSERT INTO ivt VALUES (1, 'ivl:5'), (2, 'ivl:0:3600.0'), (3, 'ivl:x'), (4, 'ivl:1:2')"
check ivl_text_roundtrip [rows "SELECT s FROM ivt ORDER BY id"] {ivl:5 ivl:0:3600.0 ivl:x ivl:1:2}
check ivl_text_compare [rows "SELECT s = 'ivl:0:3600.0' FROM ivt WHERE id = 2"] {1}
check ivl_text_not_interval [string match "*not a date*" [err "SELECT EXTRACT(HOUR FROM s) FROM ivt WHERE id = 2"]] 1
check ivl_cast_text [string match "*is not an interval*" [err "SELECT CAST(s AS INTERVAL) FROM ivt WHERE id = 2"]] 0
check ivl_real [rows "SELECT CAST(INTERVAL '1' HOUR AS TEXT), EXTRACT(HOUR FROM INTERVAL '90' MINUTE)"] {{01:00:00 1}}
run "INSERT INTO ivt VALUES (9, CAST(INTERVAL '2' HOUR AS TEXT))"
check ivl_stored_text [rows "SELECT s FROM ivt WHERE id = 9"] {02:00:00}
check ivl_like_text_param [rows "SELECT ? = s FROM ivt WHERE id = 4" [list "ivl:1:2"]] {1}

# --- randomised: no combination of string functions over hostile fragments is ever NULL ----------------
set frag [list "N" "NULL" "U" [format %c 239] [format %c 183] [format %c 144] [format %c 64975] [format %c 64977] [format %c 57344] "" " "]
set fns {
    {%s || %s}
    {CONCAT(%s, %s)}
    {REPLACE(%s, 'L', %s)}
    {COALESCE(NULLIF(%s, 'zz'), %s)}
    {SUBSTR(%s || %s, 1)}
    {TRIM(%s) || LOWER(%s)}
    {UPPER(%s) || %s}
    {CAST(CAST(%s AS BLOB) AS TEXT) || %s}
    {LPAD(%s, 6, %s)}
    {REVERSE(%s || %s)}
    {CASE WHEN 1 = 1 THEN %s || %s END}
    {(SELECT %s || %s)}
    {GROUP_CONCAT_X}
}
expr {srand(7)}
set bad 0 ; set tried 0
for {set i 0} {$i < 600} {incr i} {
    set a "'[string map {' ''} [lindex $frag [expr {int(rand()*[llength $frag])}]][lindex $frag [expr {int(rand()*[llength $frag])}]]]'"
    set b "'[string map {' ''} [lindex $frag [expr {int(rand()*[llength $frag])}]]]'"
    set fn [lindex $fns [expr {int(rand()*([llength $fns] - 1))}]]
    set sql "SELECT ([format $fn $a $b]) IS NULL"
    if {[catch {rows $sql} r]} continue
    incr tried
    if {$r ne "0"} { incr bad ; puts "FORGED: $sql -> $r" }
}
check random_no_forgery $bad 0
check random_ran [expr {$tried > 400}] 1
# multi-row aggregates over hostile stored text
check agg_group_concat [rows "SELECT GROUP_CONCAT(t, '') IS NULL FROM evil"] {0}
check agg_min_max [rows "SELECT MIN(t) IS NULL, MAX(t) IS NULL FROM evil"] {{0 0}}
check agg_empty_is_null [rows "SELECT MAX(t) IS NULL FROM evil WHERE id < 0"] {1}
check real_null_still_works [rows "SELECT NULL IS NULL, (NULL || 'a') IS NULL, COALESCE(NULL, 'z')"] {{1 1 z}}

store::closeFile $db ; file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
