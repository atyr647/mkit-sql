# Proves memory stays flat: heavy operators over a big table with a small budget, results streamed.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/scale_memory.tcl [rows] [memBytes]
# Every result is checked against numbers computed without the engine.  Peak memory is read from
# /proc (Linux) and reported relative to what the process held before the queries ran.
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set n   [expr {$argc > 0 ? [lindex $argv 0] : 500000}]
set mem [expr {$argc > 1 ? [lindex $argv 1] : 8000000}]
set mkitsql::memBytes $mem
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_scalemem_[pid].mk
file delete $f
set db [store::openFile $f -create]
store::createView $db big {{id I {}} {grp I {}} {val D {}} {name S {}}}
store::createView $db small {{id I {}} {label S {}}}
set t0 [clock milliseconds]
set sumVal 0.0 ; set nGrp 1000
for {set i 0} {$i < $n} {incr i} {
    set v [expr {($i * 37 % 10007) / 4.0}]
    set sumVal [expr {$sumVal + $v}]
    store::appendRow $db.big {id grp val name} [list $i [expr {$i % $nGrp}] $v "name[expr {$i * 7919 % $n}]"]
}
for {set i 0} {$i < $nGrp} {incr i} { store::appendRow $db.small {id label} [list $i "L$i"] }
store::commit $db
proc rss {what} { set fh [open /proc/self/status] ; set s [read $fh] ; close $fh ; regexp "$what:\\s+(\\d+)" $s -> kb ; return [expr {$kb / 1024.0}] }
puts [format "loaded %d rows in %d s;  memory budget %.1f MB;  process now holds %.0f MB" $n [expr {([clock milliseconds] - $t0) / 1000}] [expr {$mem / 1e6}] [rss VmRSS]]
set ::cnt 0 ; set ::sum 0.0 ; set ::prev "" ; set ::sorted 1 ; set ::dist [dict create]
proc cb {chunk} { incr ::cnt [llength $chunk] ; return 0 }
proc cbSum {chunk} { foreach r $chunk { set ::sum [expr {$::sum + [lindex $r 0]}] } ; incr ::cnt [llength $chunk] ; return 0 }
proc cbOrder {chunk} {
    foreach r $chunk { set k [lindex $r 0] ; if {$::prev ne "" && [string compare $::prev $k] > 0} { set ::sorted 0 } ; set ::prev $k }
    incr ::cnt [llength $chunk] ; return 0
}
set pass 0 ; set fail 0
proc t {name sql cbname want} {
    global pass fail db
    set ::cnt 0 ; set ::sum 0.0 ; set ::prev "" ; set ::sorted 1
    set base [rss VmRSS] ; set t0 [clock milliseconds]
    if {[catch {mkitsql::stream $sql $db {} $cbname} err]} { puts "FAIL $name: $err" ; incr fail ; return }
    set ms [expr {[clock milliseconds] - $t0}]
    set got [list $::cnt [expr {$cbname eq "cbSum" ? round($::sum) : ""}] [expr {$cbname eq "cbOrder" ? $::sorted : ""}]]
    set ok [expr {$got eq $want}]
    puts [format "%s %-34s %6.1f s   rows %-8d  peak %.0f MB (+%.0f)%s" [expr {$ok ? "ok  " : "FAIL"}] $name [expr {$ms / 1000.0}] $::cnt [rss VmHWM] [expr {[rss VmHWM] - $base}] [expr {$ok ? "" : "   got $got want $want"}]]
    if {$ok} { incr pass } else { incr fail }
}
set tri [expr {int($n * ($n - 1) / 2)}]
t "full table, no limit"           "SELECT id, name FROM big"                                                 cb       [list $n "" ""]
t "ORDER BY name (external sort)"  "SELECT name FROM big ORDER BY name"                                       cbOrder  [list $n "" 1]
t "ORDER BY val DESC LIMIT 10"     "SELECT id FROM big ORDER BY val DESC LIMIT 10"                            cb       [list 10 "" ""]
t "GROUP BY id (n groups)"         "SELECT id, COUNT(*) FROM big GROUP BY id"                                 cb       [list $n "" ""]
t "GROUP BY id, sum of ids"        "SELECT SUM(id) FROM (SELECT id, COUNT(*) AS c FROM big GROUP BY id) t"    cbSum    [list 1 $tri ""]
t "DISTINCT name"                  "SELECT DISTINCT name FROM big"                                            cb       [list $n "" ""]
t "DISTINCT grp (1000)"            "SELECT DISTINCT grp FROM big"                                             cb       [list $nGrp "" ""]
t "self join on id (sort-merge)"   "SELECT a.id FROM big a JOIN big b ON a.id = b.id"                         cb       [list $n "" ""]
t "join small (hash)"              "SELECT b.id, s.label FROM big b JOIN small s ON b.grp = s.id"             cb       [list $n "" ""]
t "non-equi join (nested loop) LIMIT" "SELECT a.id FROM big a JOIN small s ON a.id < s.id LIMIT 1000"         cb       [list 1000 "" ""]
t "UNION (distinct)"               "SELECT id FROM big UNION SELECT id FROM big"                              cb       [list $n "" ""]
t "INTERSECT"                      "SELECT id FROM big INTERSECT SELECT id FROM big"                          cb       [list $n "" ""]
t "EXCEPT"                         "SELECT id FROM big EXCEPT SELECT id FROM big WHERE id % 2 = 0"            cb       [list [expr {$n / 2}] "" ""]
t "window, many partitions"        "SELECT id, SUM(val) OVER (PARTITION BY grp ORDER BY id) FROM big"         cb       [list $n "" ""]
t "ROW_NUMBER over everything"     "SELECT id, ROW_NUMBER() OVER (PARTITION BY id) FROM big"                  cb       [list $n "" ""]
t "SUM streamed"                   "SELECT id FROM big"                                                       cbSum    [list $n $tri ""]
t "COUNT(DISTINCT id)"             "SELECT COUNT(DISTINCT id) FROM big"                                       cb       [list 1 "" ""]
t "COUNT(DISTINCT) per group"       "SELECT grp, COUNT(DISTINCT id), COUNT(DISTINCT name), SUM(DISTINCT id % 10) FROM big GROUP BY grp" cb [list $nGrp "" ""]
t "COUNT(DISTINCT) and GROUP BY id" "SELECT id, COUNT(DISTINCT name) FROM big GROUP BY id"                     cb       [list $n "" ""]

# statements that change data: converted into a spool first, so they are bounded too
proc d {name sql want} {
    global pass fail db
    set base [rss VmHWM] ; set t0 [clock milliseconds]
    if {[catch {mkitsql::run $sql $db} res]} { puts "FAIL $name: $res" ; incr fail ; return }
    set ms [expr {[clock milliseconds] - $t0}]
    set got [dict get $res affected]
    set ok [expr {$got == $want}]
    puts [format "%s %-34s %6.1f s   rows %-8d  peak %.0f MB (+%.0f)%s" [expr {$ok ? "ok  " : "FAIL"}] $name [expr {$ms / 1000.0}] $got [rss VmHWM] [expr {[rss VmHWM] - $base}] [expr {$ok ? "" : "   want $want"}]]
    if {$ok} { incr pass } else { incr fail }
}
mkitsql::run "BEGIN" $db
d "INSERT ... SELECT (copy)"        "CREATE TABLE copy1 AS SELECT id, grp, val, name FROM big"                $n
d "UPDATE every row"                "UPDATE copy1 SET val = val + 1, name = name || 'x'"                      $n
d "INSERT INTO ... SELECT"          "INSERT INTO copy1 SELECT id, grp, val, name FROM big WHERE id % 2 = 0"   [expr {($n + 1) / 2}]
d "MERGE (update + insert)"         "MERGE INTO copy1 c USING small s ON c.id = s.id WHEN MATCHED THEN UPDATE SET grp = 7 WHEN NOT MATCHED THEN INSERT (id, grp, val, name) VALUES (s.id + 100000000, 1, 1.5, s.label)" 1500
d "DELETE half"                     "DELETE FROM copy1 WHERE id % 2 = 1"                                       [expr {$n / 2}]
mkitsql::run "ROLLBACK" $db
puts [format "\npeak memory for the whole run: %.0f MB (data file %.0f MB, budget %.0f MB per operator)" [rss VmHWM] [expr {[file size $f] / 1e6}] [expr {$mem / 1e6}]]
puts "$pass passed, $fail failed"
store::closeFile $db ; file delete $f
exit [expr {$fail ? 1 : 0}]
