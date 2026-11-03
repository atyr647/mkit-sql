# Digest of many queries over data that trips the Tcl 8.5 / 8.6.3 list bug (first cell '#...' with several ] or "):
#   run it on each Tcl and compare the output - it must be identical everywhere (tests/listbug.sh does that)
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/budget.tcl
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_lb_[pid].mk
file delete $f
set db [mkitsql::db::openFile $f -create]
proc q {sql args} { mkitsql::run $sql $::db {*}$args }
proc esc {s} { binary scan [encoding convertto utf-8 $s] H* h ; return $h }
proc digest {sql} {
    if {[catch {q $sql} r opts]} { if {[info exists ::env(LB_DEBUG)]} { puts stderr "ERRMSG: $r\n[dict get $opts -errorinfo]" } ; return "ERR [lrange [dict get $opts -errorcode] 0 3]" }
    set o {}
    foreach row [dict get $r rows] {
        set cells {} ; foreach c $row { lappend cells [esc $c] }
        lappend o [join $cells ,]
    }
    return [join [lsort $o] " "]
}
set pool [list "#\]\]x" "#\]\]=\]a" "#\"q\" \"t\"" "#\]\]\]\]\]z" "#\]a" "plain" "#\{\}\]\]" "#\]\] sp\]\]" "#\"\"" "#" "##\]\]" "#\[a\]\[b\]" "z\]\]" "#a b\\\\" "#\"\]" "#\]\"\]\"" "" "#\n\]\]"]
expr {srand([expr {[info exists ::env(LB_SEED)] ? $::env(LB_SEED) : 11}])}
proc pick {} { global pool ; lindex $pool [expr {int(rand() * [llength $pool])}] }
proc lit {s} { return "'[string map {' ''} $s]'" }
q "CREATE TABLE a (s TEXT, t TEXT, n INT)"
q "CREATE TABLE b (s TEXT, u TEXT, m INT)"
for {set i 0} {$i < 60} {incr i} {
    q "INSERT INTO a VALUES ([lit [pick]], [lit [pick]], [expr {int(rand()*10)}])"
    q "INSERT INTO b VALUES ([lit [pick]], [lit [pick]], [expr {int(rand()*10)}])"
}
foreach sql {
    "SELECT s, t, n FROM a" "SELECT s FROM a ORDER BY s, t, n" "SELECT DISTINCT s, t FROM a" "SELECT s, COUNT(*), MIN(t), MAX(n) FROM a GROUP BY s"
    "SELECT s, t, COUNT(*) FROM a GROUP BY s, t" "SELECT s, COUNT(DISTINCT t) FROM a GROUP BY s" "SELECT a.s, b.u FROM a JOIN b ON a.s = b.s"
    "SELECT a.s, a.t, b.u FROM a LEFT JOIN b ON a.s = b.s AND a.t = b.u" "SELECT a.s, b.s FROM a, b WHERE a.t = b.u" "SELECT s, t FROM a UNION SELECT s, u FROM b"
    "SELECT s, t FROM a INTERSECT SELECT s, u FROM b" "SELECT s FROM a EXCEPT SELECT s FROM b" "SELECT s, t FROM a UNION ALL SELECT s, u FROM b"
    "SELECT s, ROW_NUMBER() OVER (PARTITION BY s ORDER BY t, n) FROM a" "SELECT s, SUM(n) OVER (PARTITION BY t) FROM a"
    "SELECT s, t FROM a WHERE s IN (SELECT s FROM b)" "SELECT s FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.s = a.s)" "SELECT s FROM a WHERE s = ANY (SELECT u FROM b)"
    "SELECT x.s, x.t FROM (SELECT s, t FROM a) x" "WITH c AS (SELECT s, t FROM a) SELECT s, t FROM c" "WITH c AS (SELECT s, t, n FROM a) SELECT c.s, d.s FROM c JOIN c d ON c.t = d.t"
    "SELECT (s, t) IN (SELECT s, u FROM b) FROM a" "SELECT s || t, LENGTH(s) FROM a" "SELECT UPPER(s), SUBSTR(s, 1, 3) FROM a" "SELECT s, t FROM a ORDER BY t DESC, s LIMIT 7 OFFSET 3"
    "SELECT s, STRING_AGG(t, '|' ORDER BY t) FROM a GROUP BY s" "SELECT s, t FROM a WHERE s LIKE '#%' AND t NOT LIKE '#%'" "SELECT s FROM a GROUP BY s HAVING COUNT(*) > 1"
    "WITH RECURSIVE r(s, t) AS (SELECT s, t FROM a UNION SELECT s, t FROM r) SELECT s, t FROM r" "SELECT * FROM (VALUES ('#]]x', '#\"\"'), ('#]]=]a', 'q')) v(p, q)"
    "SELECT * FROM a" "SELECT a.* FROM a JOIN b ON a.n = b.m" "SELECT s, t FROM a a1 WHERE n > (SELECT MIN(m) FROM b WHERE b.s = a1.s)"
} { puts "[format %-3d [incr ::qn]] [digest $sql]" }
# writes: copy, update, delete, merge, then read back
q "CREATE TABLE c (s TEXT, t TEXT, n INT)"
q "INSERT INTO c SELECT s, t, n FROM a"
puts "ins [digest {SELECT s, t, n FROM c}]"
q "UPDATE c SET t = s || '!' WHERE n > 4"
puts "upd [digest {SELECT s, t, n FROM c}]"
q "DELETE FROM c WHERE n IN (1, 2, 3)"
puts "del [digest {SELECT s, t, n FROM c}]"
puts "merge-dup [digest {MERGE INTO c USING (SELECT s, u, m FROM b) x ON c.s = x.s WHEN MATCHED THEN UPDATE SET t = x.u WHEN NOT MATCHED THEN INSERT (s, t, n) VALUES (x.s, x.u, x.m)}]"
q "MERGE INTO c USING (SELECT s, MIN(u) AS u, MIN(m) AS m FROM b GROUP BY s) x ON c.s = x.s WHEN MATCHED THEN UPDATE SET t = x.u WHEN NOT MATCHED THEN INSERT (s, t, n) VALUES (x.s, x.u, x.m)"
puts "mrg [digest {SELECT s, t, n FROM c}]"
q "CREATE TABLE d AS SELECT s, t FROM c"
puts "ctas [digest {SELECT s, t FROM d}]"
q "COMMIT"
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f]
puts "reopen [digest {SELECT s, t, n FROM c}]"
mkitsql::db::closeFile $db ; file delete $f
