# Everything the engine can spill to disk must come back EXACTLY: strings with newlines, carriage returns,
# backslashes, braces, quotes, leading/trailing blanks, empty strings, NUL-bearing blobs, non-ASCII, very long
# values.  Each query runs with a large budget (all in memory) and with tiny budgets (everything spills); the
# results must be identical, and the values that come out must be the values that went in.
#   tclsh tests/spillroundtrip.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_sr_[pid].mk
file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 400]\n   want: [string range $want 0 400]" }
}
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }
proc setBudget {mem chunk} { set ::mkitsql::memBytes $mem ; set ::mkitsql::chunk $chunk }

set nasty [list "" " " "  lead" "trail  " "a b" "line1\nline2" "cr\rlf" "crlf\r\n" "\n" "\r" "\n\n\r\r" "tab\there" \
    "back\\slash" "\\" "\\\\" "\\n" "\\r" "trailing\\" "\\\n" "{" "}" "{}" "{ }" "\{a\} b" "\"" "'" "\"quoted\"" "it's" \
    "\[x\]" "\$y" ";" "#" "x;y" "a,b" "a\"b,c" "caf[format %c 233]" "[format %c 937][format %c 9731]" "[format %c 20013][format %c 25991]" \
    "[format %c 128512]" "ZZZ" "zzz" "AAA" "aaa" "10" "9" "2" "007" "1e3" "0x10" "-5" "+5" ".5" "NULL" "null" "ivl:5" \
    [string repeat "long " 800] [string repeat "x" 5000] [string repeat "\n" 300] "a\\\\nb" "\\u00e9" "%s %d" "{a" "b}" "\\{" "\\}"]
# keep them distinct but allow duplicates deliberately (id order differs from value order)
set n 0 ; set vals {}
foreach s $nasty { lappend vals $s ; lappend vals $s }
set n [llength $vals]
mkitsql::db::createView $db t {{id I {}} {g I {}} {s S {}} {b B {}} {r D {}}}
set id 0
foreach s $vals {
    set blob [binary format c* [list [expr {$id % 256}] 0 10 13 92 255 [expr {($id * 7) % 256}]]]
    mkitsql::db::appendRow $db.t {id g s b r} [list $id [expr {$id % 5}] $s $blob [expr {($id * 37 % 101) / 4.0}]]
    incr id
}
mkitsql::db::createView $db u {{k S {}} {w I {}}}
set id 0
foreach s $nasty { mkitsql::db::appendRow $db.u {k w} [list $s [incr id]] }
mkitsql::db::commit $db

# --- the data itself comes back exactly (through a sort that spills) -------------------------------------
setBudget 1 1
set got {}
foreach r [rows "SELECT s FROM t ORDER BY s, id"] { lappend got [lindex $r 0] }
check data_sorted_multiset [lsort $got] [lsort $vals]
set got {}
foreach r [rows "SELECT id, s FROM t ORDER BY s DESC, id"] { lappend got [lindex $r 1] }
check data_sorted_desc_multiset [lsort $got] [lsort $vals]
setBudget 1 1
set ok 1
foreach r [rows "SELECT id, s FROM t ORDER BY b, id"] { lassign $r i s ; if {$s ne [lindex $vals $i]} { set ok 0 ; puts "value of id $i changed through a spilled sort" } }
check data_follows_id $ok 1
setBudget 1 1
set ok 1
foreach r [rows "SELECT id, b FROM t ORDER BY b DESC, id"] {
    lassign $r i b
    set want [binary format c* [list [expr {$i % 256}] 0 10 13 92 255 [expr {($i * 7) % 256}]]]
    if {$b ne $want} { set ok 0 ; puts "blob of id $i changed" }
}
check blobs_exact $ok 1

# --- same results in memory and spilled ---------------------------------------------------------------------
set queries {
    {SELECT s, id FROM t ORDER BY s, id}
    {SELECT s, id FROM t ORDER BY s DESC, id DESC}
    {SELECT id, b FROM t ORDER BY b, id}
    {SELECT id FROM t ORDER BY r DESC, s, id LIMIT 25}
    {SELECT DISTINCT s FROM t ORDER BY s}
    {SELECT DISTINCT b FROM t ORDER BY b}
    {SELECT DISTINCT s, g FROM t ORDER BY s, g}
    {SELECT s, COUNT(*), MIN(b), MAX(b), SUM(r), AVG(r), MIN(s), MAX(s) FROM t GROUP BY s ORDER BY s}
    {SELECT g, COUNT(*), COUNT(DISTINCT s), COUNT(DISTINCT b), SUM(DISTINCT r), AVG(DISTINCT r), MIN(s), MAX(s) FROM t GROUP BY g ORDER BY g}
    {SELECT COUNT(DISTINCT s), COUNT(DISTINCT b), COUNT(DISTINCT g), SUM(DISTINCT g), COUNT(*) FROM t}
    {SELECT s, COUNT(DISTINCT id) FROM t GROUP BY s HAVING COUNT(*) > 1 ORDER BY s}
    {SELECT a.id, b.id FROM t a JOIN t b ON a.s = b.s AND a.id < b.id ORDER BY a.id, b.id}
    {SELECT a.id, b.id FROM t a JOIN t b ON a.b = b.b ORDER BY a.id, b.id}
    {SELECT t.id, u.w FROM t LEFT JOIN u ON t.s = u.k ORDER BY t.id}
    {SELECT t.id, u.w FROM t RIGHT JOIN u ON t.s = u.k ORDER BY u.w, t.id}
    {SELECT t.id, u.w FROM t FULL JOIN u ON t.s = u.k ORDER BY t.id, u.w}
    {SELECT t.id, u.w FROM t JOIN u ON t.g < u.w AND t.id < 12 ORDER BY t.id, u.w}
    {SELECT t.id, u.w FROM t, u WHERE t.id = u.w * 2 ORDER BY t.id}
    {SELECT s FROM t UNION SELECT k FROM u ORDER BY 1}
    {SELECT s FROM t UNION ALL SELECT k FROM u ORDER BY 1}
    {SELECT s FROM t INTERSECT SELECT k FROM u ORDER BY 1}
    {SELECT s FROM t EXCEPT SELECT k FROM u WHERE w > 20 ORDER BY 1}
    {SELECT k FROM u EXCEPT SELECT s FROM t WHERE g = 0 ORDER BY 1}
    {SELECT id, ROW_NUMBER() OVER (PARTITION BY s ORDER BY id) FROM t ORDER BY id}
    {SELECT id, RANK() OVER (ORDER BY s), DENSE_RANK() OVER (PARTITION BY g ORDER BY s) FROM t ORDER BY id}
    {SELECT id, LAG(s) OVER (PARTITION BY g ORDER BY id), LEAD(s, 2) OVER (ORDER BY id) FROM t ORDER BY id}
    {SELECT id, SUM(r) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), FIRST_VALUE(s) OVER (PARTITION BY g ORDER BY id) FROM t ORDER BY id}
    {SELECT id FROM t WHERE s IN (SELECT k FROM u WHERE w % 2 = 0) ORDER BY id}
    {SELECT id FROM t WHERE s NOT IN (SELECT k FROM u WHERE w < 20) ORDER BY id}
    {SELECT id FROM t x WHERE EXISTS (SELECT 1 FROM u WHERE u.k = x.s AND u.w > 3) ORDER BY id}
    {SELECT id, (SELECT MAX(w) FROM u WHERE u.k = x.s) FROM t x ORDER BY id}
    {SELECT id FROM t x WHERE s = ANY (SELECT k FROM u WHERE w > 10) ORDER BY id}
    {WITH RECURSIVE c(n, v) AS (SELECT 1, 'a' UNION ALL SELECT n + 1, v || 'b' FROM c WHERE n < 30) SELECT n, v FROM c ORDER BY n}
    {SELECT g, COUNT(*) FROM (SELECT DISTINCT s, g FROM t) d GROUP BY g ORDER BY g}
    {SELECT s FROM t GROUP BY s ORDER BY s LIMIT 7 OFFSET 3}
}
set budgets {{1 1} {1 3} {50 3} {400 7} {2000 11} {100000 1000}}
set qn 0
foreach sql $queries {
    incr qn
    setBudget 33554432 2000
    if {[catch {rows $sql} want]} { check "q$qn baseline ran ($sql)" $want "rows" ; continue }
    check "q$qn returns rows (not vacuous): [string range $sql 0 50]" [expr {[llength $want] > 0}] 1
    foreach bc $budgets {
        setBudget {*}$bc
        if {[catch {rows $sql} got]} { check "q$qn budget $bc ($sql)" $got "rows" ; continue }
        check "q$qn budget $bc: [string range $sql 0 60]" $got $want
    }
}
setBudget 33554432 2000

# --- statements that change data give the same table in memory and spilled ---------------------------------------
proc dumpTable {name} { rows "SELECT * FROM $name ORDER BY 1, 2, 3" }
foreach {label setup stmt} {
    ctas   {}  {CREATE TABLE w AS SELECT id, s, b, r FROM t WHERE g <> 2}
    insel  {CREATE TABLE w (id INT, s TEXT, b BLOB, r REAL)} {INSERT INTO w SELECT id, s, b, r FROM t WHERE id % 3 = 0}
    update {CREATE TABLE w AS SELECT id, s, b, r FROM t} {UPDATE w SET s = s || '|' || s, r = r + 1 WHERE id % 2 = 0}
    delete {CREATE TABLE w AS SELECT id, s, b, r FROM t} {DELETE FROM w WHERE s IN (SELECT k FROM u WHERE w % 3 = 0) OR id % 7 = 0}
    merge  {CREATE TABLE w AS SELECT id, s, b, r FROM t WHERE id < 40} {MERGE INTO w USING (SELECT w AS i, k AS kk FROM u) src ON w.id = src.i WHEN MATCHED AND w.id % 2 = 0 THEN UPDATE SET s = src.kk WHEN MATCHED THEN DELETE WHEN NOT MATCHED THEN INSERT (id, s, b, r) VALUES (src.i + 1000, src.kk, 'x', 1.5)}
} {
    set res {}
    foreach bc [list {33554432 2000} {1 1} {50 3} {400 7}] {
        setBudget {*}$bc
        catch {q "DROP TABLE w"}
        if {$setup ne ""} { q $setup }
        q $stmt
        lappend res [dumpTable w]
    }
    check "dml_$label: spilled == in-memory (50 vs mem)" [lindex $res 2] [lindex $res 0]
    check "dml_$label: spilled == in-memory (1/1)" [lindex $res 1] [lindex $res 0]
    check "dml_$label: spilled == in-memory (400/7)" [lindex $res 3] [lindex $res 0]
    catch {q "DROP TABLE w"}
}
# and no spill file may be left behind
setBudget 1 1
rows "SELECT s FROM t ORDER BY s"
check no_spill_files_left [llength [glob -nocomplain -directory [mkitsql::tmpDir] mkitsql_[pid]_*.spill]] 0

mkitsql::db::closeFile $db
file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
