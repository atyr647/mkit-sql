# Regression tests for the defects found by two independent adversarial reviews (code generation / functions, and
# storage / locks / spill).  Each check is the reviewer's reproduction.
#   tclsh tests/review_regress.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/budget.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_rr_[pid].mk
file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc q {sql args} { mkitsql::run $sql $::db {*}$args }
proc rows {sql args} { dict get [q $sql {*}$args] rows }
# the outcome of a statement: ok, a clean engine error, or a raw/RUNTIME error (a defect)
proc outcome {sql args} {
    if {![catch {q $sql {*}$args} r opts]} { return ok }
    set code [dict get $opts -errorcode]
    if {[lindex $code 0] eq "MKQL" && [lindex $code 2] ne "RUNTIME"} { return clean }
    return "RAW [lrange $code 0 4]: [string range $r 0 80]"
}
q "CREATE TABLE t (id INT, s TEXT, n REAL)"
q "INSERT INTO t VALUES (1, 'abc', 1.5), (2, 'xyz', 2.5)"

# ---- S1: CHR wrapped around to U+FDD0 and forged NULL / INTERVAL ----------------------------------------------------------------
foreach n {64976 -4294902320 4294967296 4294967296.5 -4294967296 18446744073709551616 9223372036854775807 -1 1114112 55296 57343 4294902320 64976.4 1e300 -1e300 NaN Inf} {
    set o [outcome "SELECT CHR($n)"]
    check "S1 CHR($n) refused" $o clean
}
check S1_forged_null_gone [rows "SELECT CASE WHEN CHR(64977) || 'NULL' IS NULL THEN 'forged' ELSE 'not null' END"] [list [list "not null"]]
check S1_no_interval_from_text [outcome "SELECT EXTRACT(MONTH FROM (CHR(-4294902320) || 'ivl:14:90061'))"] clean
check S1_chr_ok [rows "SELECT CHR(65), CHR(233), CHR(8364), LENGTH(CHR(128512)), CHR(0) = '', ASCII(CHR(8364))"] [list [list A [format %c 233] [format %c 8364] 1 0 8364]]

# ---- S3: one short statement must not exhaust memory or run for ever ----------------------------------------------------------------
foreach {label sql} {
    lpad     "SELECT LPAD('x', 2000000000)"          rpad    "SELECT RPAD('x', 2000000000, 'ab')"
    repeat   "SELECT REPEAT('x', 2000000000)"        repeat2 "SELECT REPEAT('abcdefgh', 9000000000000)"
    round    "SELECT ROUND(1.5, -100000000)"         trunc   "SELECT TRUNC(1.5, 100000000)"
    round2   "SELECT ROUND(1.5, -9000000000000000000)"
} {
    set t0 [clock milliseconds] ; set o [outcome $sql] ; set ms [expr {[clock milliseconds] - $t0}]
    check "S3 $label does not run away" [expr {$o in {ok clean} && $ms < 2000}] 1
}
check S3_round_values [rows "SELECT ROUND(1.5, -100000000), ROUND(1.5, 100000000), TRUNC(2.7, -500), ROUND(123.456, 1)"] {{0.0 1.5 0.0 123.5}}
check S3_repeat_ok [rows "SELECT REPEAT('ab', 3), LPAD('x', 4, 'ab'), RPAD('x', 4, 'ab'), LENGTH(REPEAT('z', 100000))"] {{ababab abax xaba 100000}}
# a chain that doubles a string every step ends in an error, not in memory exhaustion
set mkitsql::maxString 1000000
set t0 [clock milliseconds]
set o [outcome "WITH RECURSIVE r(s, n) AS (SELECT 'x', 0 UNION ALL SELECT s || s, n + 1 FROM r WHERE n < 60) SELECT LENGTH(s) FROM r ORDER BY n DESC LIMIT 1"]
check S3_doubling_cte_stops [list $o [expr {[clock milliseconds] - $t0 < 10000}]] {clean 1}
set mkitsql::maxString 67108864

# ---- S4: arguments of the wrong kind are engine errors, not Tcl errors ---------------------------------------------------------------
foreach sql {
    "SELECT CHR(99999999999)" "SELECT CHR(-9223372036854775808)" "SELECT ABS(x'ff')" "SELECT SQRT(x'ff')" "SELECT LEFT('', 1.5)" "SELECT RIGHT('', 1e400)"
    "SELECT REPEAT('abc', 1.5)" "SELECT LPAD('0', 1.5)" "SELECT SUBSTR('abcdef', '', 1)" "SELECT SUBSTRING(s FROM 'x' FOR 'x') FROM t"
    "SELECT POWER(0, -1)" "SELECT ASIN(2)" "SELECT ACOS(-2)" "SELECT SIN('1e400')" "SELECT ROUND(1e-320, 1.5)" "SELECT INTERVAL '3' SECOND * 1e308"
    "SELECT CAST(s AS INT) FROM t WHERE id = 1e999" "SELECT * FROM t WHERE id = 1e999" "SELECT LN(0)" "SELECT SQRT(-1)" "SELECT 1 / 0" "SELECT 5 % 0" "SELECT 1e308 * 1e308"
    "SELECT 9223372036854775807 + 1" "SELECT -9223372036854775808 - 1" "SELECT 9223372036854775807 * 2" "SELECT ABS(-9223372036854775808)" "SELECT CAST(1e30 AS INT)"
    "SELECT SUBSTR('abc', 9223372036854775807, 9223372036854775807)" "SELECT SUBSTR('abc', -9223372036854775808, 5)" "SELECT LPAD('x', -5)" "SELECT TRIM('abc', NULL)"
    "SELECT s LIKE REPLACE('_', '_', '________________________________________________________________________________') FROM t"
    "SELECT EXTRACT(DAY FROM DATE '2026-01-01' + INTERVAL '99999999999999' YEAR)" "SELECT DATE '2026-01-01' + INTERVAL '1e30' DAY"
    "SELECT POWER(10, 400)" "SELECT POWER(2.5, 1e10)" "SELECT EXP(1000)" "SELECT TAN(1e300)" "SELECT DEGREES(1e308)" "SELECT GREATEST(1, 'a')" "SELECT LEAST(x'ff', 1)"
} {
    check "S4 $sql" [expr {[outcome $sql] in {ok clean}}] 1
}
foreach p {1e999 -1e999 abc {} 99999999999999999999} {
    q "CREATE TABLE IF NOT EXISTS pi (a INT, b REAL, c TEXT)"
    check "S4 parameter $p into INT column" [expr {[outcome "INSERT INTO pi (a) VALUES (?)" [list $p]] in {ok clean}}] 1
    check "S4 parameter $p into REAL column" [expr {[outcome "INSERT INTO pi (b) VALUES (?)" [list $p]] in {ok clean}}] 1
}
q "ROLLBACK"



# ---- R1: spill files are checked: a short, damaged or unwritable file stops the statement ----------------------------------------
proc spillCase {mutate} {
    set saved $::mkitsql::memBytes ; set ::mkitsql::memBytes 200
    set sp [mkitsql::spoolNew]
    for {set i 0} {$i < 50} {incr i} { mkitsql::spoolAdd $sp [list [list "row $i" "#\]\]x" $i]] }
    mkitsql::spoolSeal $sp
    set path $::mkitsql::S($sp,path)
    set ::mkitsql::memBytes $saved
    if {$path eq ""} { return "not spilled" }
    {*}$mutate $path
    set rc [catch {mkitsql::spoolList $sp} r opts]
    catch {mkitsql::spoolFree $sp} ; mkitsql::spillCleanup
    return [expr {$rc ? [lindex [dict get $opts -errorcode] 0] : "ok [llength $r]"}]
}
proc noChange {path} {}
proc chopTail {path} { set f [open $path r+] ; fconfigure $f -translation binary ; set n [file size $path] ; chan truncate $f [expr {$n - 30}] ; close $f }
proc chopTrailer {path} { set f [open $path r] ; set d [read $f] ; close $f ; set d [string range $d 0 [expr {[string last "\n\\E" $d]}]] ; set f [open $path w] ; puts -nonewline $f $d ; close $f }
proc dropLine {path} { set f [open $path r] ; set l [split [read $f] "\n"] ; close $f ; set f [open $path w] ; puts -nonewline $f [join [lreplace $l 3 3] "\n"] ; close $f }
check R1_intact_file_reads [spillCase noChange] "ok 50"
check R1_truncated_file_fails [spillCase chopTail] MKQL
check R1_missing_trailer_fails [spillCase chopTrailer] MKQL
check R1_dropped_record_fails [spillCase dropLine] MKQL
# a write error on the last buffered write must not be swallowed at close
set path [mkitsql::spillNewPath] ; set ch [mkitsql::spillOpenW $path]
mkitsql::spillWrite $ch [list [list a b]]
set okRaw [catch {chan close $ch}] ; # (the channel is closed behind the engine's back: closing it again must report, not hide)
check R1_close_error_reported [expr {[catch {mkitsql::spillClose $ch} m opts] ? [lindex [dict get $opts -errorcode] 0] : "swallowed"}] MKQL
mkitsql::spillCleanup

# ---- R4 / R5: transaction ownership and statements that fail halfway --------------------------------------------------------------
set tag [lindex [mkitsql::db::tags] 0]
q "CREATE TABLE tx (id INT, v TEXT)" ; q "INSERT INTO tx VALUES (1, 'one')" ; q COMMIT
# a failure while the rows are being applied (injected into the storage layer) after some rows were already written
rename ::mkitsql::db::appendRow ::mkitsql::db::appendRow_real
set ::failAfter 3 ; set ::failCount 0
proc ::mkitsql::db::appendRow {args} { if {[incr ::failCount] > $::failAfter} { error "injected storage failure" } ; ::mkitsql::db::appendRow_real {*}$args }
set rc [catch {q "INSERT INTO tx SELECT id + 10, 'x' FROM (VALUES (1), (2), (3), (4), (5), (6)) v(id)"} m]
check R5_failed_insert_reports $rc 1
check R5_message_says_rolled_back [string match "*rolled back*" $m] 1
check R5_nothing_left_pending [mkitsql::db::dirty $tag] 0
check R5_table_unchanged [rows "SELECT COUNT(*) FROM tx"] 1
# the same failure with earlier uncommitted work pending: the transaction is marked failed
set ::failAfter 1000
q "INSERT INTO tx VALUES (2, 'two')"
set ::failAfter 3 ; set ::failCount 0
set rc [catch {q "INSERT INTO tx SELECT id + 10, 'x' FROM (VALUES (1), (2), (3), (4), (5), (6)) v(id)"} m]
check R5_pending_failure_reports $rc 1
check R5_message_says_run_rollback [string match "*ROLLBACK*" $m] 1
rename ::mkitsql::db::appendRow {} ; rename ::mkitsql::db::appendRow_real ::mkitsql::db::appendRow
check R5_write_refused_when_failed [outcome "INSERT INTO tx VALUES (3, 'three')"] clean
check R5_commit_refused_when_failed [outcome "COMMIT"] clean
q "ROLLBACK"
check R5_rollback_restores [rows "SELECT id FROM tx ORDER BY id"] 1
check R5_writes_work_again [outcome "INSERT INTO tx VALUES (3, 'three')"] ok
q "ROLLBACK"
# sessions: a failed statement that changed nothing does not make its session the owner
set mkitsql::session A
catch {q "INSERT INTO tx VALUES ('notanumber', 'x')"}
set mkitsql::session B
check R4_failed_statement_leaves_no_owner [outcome "INSERT INTO tx VALUES (5, 'b')"] ok
set mkitsql::session A
check R4_other_session_refused [outcome "INSERT INTO tx VALUES (6, 'a')"] clean
# the transaction ends through the storage layer (as MK Studio's UI does), not through a statement: the old owner must not linger
mkitsql::db::commit $tag
set mkitsql::session A
check R4_stale_owner_dropped [outcome "INSERT INTO tx VALUES (7, 'a')"] ok
set mkitsql::session B
check R4_new_owner_enforced [outcome "INSERT INTO tx VALUES (8, 'b')"] clean
set mkitsql::session A
q "ROLLBACK"
set mkitsql::session ""
q "DROP TABLE tx" ; q COMMIT


# ---- R9-R11 -------------------------------------------------------------------------------------------------------------------------
q "CREATE TABLE fr (r REAL, d DOUBLE PRECISION)"
check R11_real_range [outcome "INSERT INTO fr (r) VALUES (1e39)"] clean
check R11_real_range_param [outcome "INSERT INTO fr (r) VALUES (?)" {1e39}] clean
check R11_real_ok [outcome "INSERT INTO fr (r) VALUES (3e38)"] ok
check R11_double_ok [outcome "INSERT INTO fr (d) VALUES (1e300)"] ok
check R11_no_infinity_stored [rows "SELECT COUNT(*) FROM fr WHERE r > 1e39 OR d > 1e308"] 0
q "ROLLBACK"
# 8.5: a cross join / left join with an empty side builds a row of 0 NULLs (lrepeat 0 fails on 8.5)
q "CREATE TABLE e0 (a INT)" ; q "CREATE TABLE e1 (b INT)" ; q "INSERT INTO e1 VALUES (1)"
check R11_empty_side_join [rows "SELECT b FROM e1 LEFT JOIN e0 ON e0.a = e1.b"] 1
check R11_empty_values_row [outcome "SELECT * FROM (VALUES (1)) v(x) FULL JOIN e0 ON 1 = 0"] ok
q "ROLLBACK"
set bad [expr {[catch {mkitsql::db::openFile $::tmp/no_such_dir/x.mk} m] ? $m : "opened"}]
check R11_open_error_names_path [string match "*no_such_dir/x.mk*" $bad] 1
# the type memory of an open file dies with it: a closed and reopened file may be changed to another type
set f2 $::tmp/mkitsql_rr2_[pid].mk ; file delete $f2
set d2 [mkitsql::db::openFile $f2 -create]
mkitsql::run "CREATE TABLE w (x INT)" $d2 ; mkitsql::run "INSERT INTO w VALUES (1)" $d2 ; mkitsql::run COMMIT $d2
mkitsql::run "DROP TABLE w" $d2 ; mkitsql::run COMMIT $d2
mkitsql::db::closeFile $d2
set d2 [mkitsql::db::openFile $f2]
check R10_type_memory_cleared [expr {[catch {mkitsql::run "CREATE TABLE w (x TEXT)" $d2} m] ? $m : "ok"}] ok
mkitsql::run "INSERT INTO w VALUES ('hello')" $d2 ; mkitsql::run COMMIT $d2
check R10_text_stored [dict get [mkitsql::run "SELECT x FROM w" $d2] rows] hello
mkitsql::db::closeFile $d2 ; file delete $f2

# ---- S6 / S7 --------------------------------------------------------------------------------------------------------------------
foreach {name sql} {
    s6_table "CREATE TABLE __mks_tmp_1 (a INT)" s6_column "CREATE TABLE zz (a INT, __MKS_x INT)" s6_add "ALTER TABLE t ADD COLUMN __mks_tmp_5 INT"
    s6_rename "ALTER TABLE t RENAME COLUMN s TO __mks_q" s7_derived "SELECT * FROM (SELECT 1 AS a, 2 AS a) x" s7_ref "SELECT a FROM (SELECT 1 AS a, 2 AS a) x"
    s7_cte "WITH c(a, a) AS (SELECT 1, 2) SELECT * FROM c" s7_alias "SELECT * FROM (SELECT 1, 2) x(p, p)"} {
    check "S_$name" [outcome $sql] clean
}
check S7_distinct_ok [rows "SELECT * FROM (SELECT 1 AS a, 2 AS b) x"] {{1 2}}

# ---- S2: nesting depth must not blow up ---------------------------------------------------------------------------------------
set sql "SELECT 1 AS x"
for {set i 0} {$i < 60} {incr i} { set sql "SELECT x FROM ($sql) t$i WHERE x = 1" }
set t0 [clock milliseconds]
check S2_derived_depth60 [rows $sql] 1
check S2_derived_fast [expr {[clock milliseconds] - $t0 < 5000}] 1
set sql "WITH c0 AS (SELECT 1 AS x)"
for {set i 1} {$i <= 30} {incr i} { append sql ", c$i AS (SELECT a.x FROM c[expr {$i-1}] a JOIN c[expr {$i-1}] b ON a.x = b.x)" }
append sql " SELECT * FROM c30"
set t0 [clock milliseconds]
check S2_cte_chain_clean_error [outcome $sql] clean
check S2_cte_chain_fast [expr {[clock milliseconds] - $t0 < 5000}] 1

# ---- S5: Tcl 8.5 / 8.6.3 damage the string form of a list whose first element is '#...' with two or more ] or " ----------------
# (`join` reads the elements, never the string form, so the test itself is not hit by the bug)
set hashy [list "#\]\]x" "#\]\]=\]a" "#\"quoted\" \"text\"" "#\]\]\]\]\]z" "#\]a" "plain" "#\{\}\]\]" "#\]\] sp\]\]" "#\"\"" "#"]
q "CREATE TABLE hz (a TEXT, b TEXT, n INT)"
set i 0
foreach v $hashy { q "INSERT INTO hz VALUES (?, ?, ?)" [list $v b$i $i] ; incr i }
proc firsts {rs} { set o {} ; foreach r $rs { lappend o [lindex $r 0] } ; return [join [lsort $o] "|"] }
proc firstsRow {rs} { set o {} ; foreach r $rs { lappend o [lindex $r 0] [lindex $r 1] } ; return [join [lsort $o] "|"] }
set want [join [lsort $hashy] "|"]
foreach {name sql} [list \
    select "SELECT a, b FROM hz" order "SELECT a, n FROM hz ORDER BY a" group "SELECT a, COUNT(*) FROM hz GROUP BY a" \
    distinct "SELECT DISTINCT a, b FROM hz" self_join "SELECT x.a, y.b FROM hz x JOIN hz y ON x.a = y.a" \
    union "SELECT a, b FROM hz UNION SELECT a, b FROM hz" intersect "SELECT a, b FROM hz INTERSECT SELECT a, b FROM hz" \
    window "SELECT a, ROW_NUMBER() OVER (ORDER BY a) FROM hz" cte "WITH c AS (SELECT a, b FROM hz) SELECT a, b FROM c" \
    count_distinct "SELECT a, COUNT(DISTINCT b) FROM hz GROUP BY a" recursive "WITH RECURSIVE r(a, b) AS (SELECT a, b FROM hz UNION SELECT a, b FROM r) SELECT a, b FROM r"] {
    set got [firsts [rows $sql]]
    check "S5_hash_first_$name" $got $want
}
q "CREATE TABLE hz2 (a TEXT, b TEXT, n INT)"
q "INSERT INTO hz2 SELECT a, b, n FROM hz"
check S5_insert_select [firsts [rows "SELECT a, b FROM hz2"]] $want
q "UPDATE hz2 SET b = 'z'"
check S5_update [firsts [rows "SELECT a, b FROM hz2"]] $want
check S5_values [firsts [rows "SELECT * FROM (VALUES ('#\]\]x', 1), ('#\]\]=\]a', 2)) v(a, b)"]] [join [lsort [list "#\]\]x" "#\]\]=\]a"]] "|"]
# what the caller receives must also be intact when it prints a row
set rr [lindex [rows "SELECT a, b FROM hz WHERE n = 1"] 0]
check S5_row_string_form [expr {[llength [string range $rr 0 end]] == 2 && [lindex [string range $rr 0 end] 0] eq [lindex $hashy 1]}] 1
q "ROLLBACK"
set long [string repeat _ 100000]
check S4_huge_like_pattern [expr {[outcome "SELECT s LIKE ? FROM t" [list $long]] in {ok clean}}] 1
check S4_huge_like_literal [expr {[outcome "SELECT s LIKE '$long' FROM t"] in {ok clean}}] 1

mkitsql::db::closeFile $db
file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
