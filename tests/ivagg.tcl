# SUM / AVG / MIN / MAX over INTERVAL values: plain, grouped, DISTINCT, windowed, and with a memory budget so small that the
# aggregator spills and merges partial states.  Expected values are worked out here from months and seconds.
#   tclsh tests/ivagg.tcl        (MKIT_MEMBYTES=2000 tclsh tests/ivagg.tcl  for the spilling run)
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_iv_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc q {sql} { mkitsql::run $sql $::db }
q "CREATE TABLE t (id INT, g INT, d INT, s INT, m INT)"
expr {srand(3)}
set rows {} ; set vals {}
for {set i 1} {$i <= 600} {incr i} {
    set g [expr {int(rand() * 25)}] ; set d [expr {int(rand() * 40) - 10}] ; set s [expr {int(rand() * 5000)}] ; set m [expr {int(rand() * 5)}]
    lappend rows [list $i $g $d $s $m] ; lappend vals "($i, $g, $d, $s, $m)"
}
q "INSERT INTO t VALUES [join $vals ,]"
q COMMIT
# interval of a row: m months + d days + s seconds
set iv "(INTERVAL '1' MONTH * m + INTERVAL '1' DAY * d + INTERVAL '1' SECOND * s)"
proc ivOf {r} { lassign $r i g d s m ; return [list $m [expr {$d * 86400 + $s}]] }
proc fmt {ms} { lassign $ms m s ; return [mkitsql::ivFormat [mkitsql::ivMake $m $s]] }
proc total {ms} { lassign $ms m s ; expr {$m * 2592000.0 + $s} }
proc sumOf {l} { set m 0 ; set s 0 ; foreach x $l { incr m [lindex $x 0] ; set s [expr {$s + [lindex $x 1]}] } ; return [list $m $s] }
# whole table
set all {} ; foreach r $rows { lappend all [ivOf $r] }
set got [lindex [dict get [q "SELECT SUM($iv), MIN($iv), MAX($iv) FROM t"] rows] 0]
set mn [lindex $all 0] ; set mx [lindex $all 0]
foreach x $all { if {[total $x] < [total $mn]} { set mn $x } ; if {[total $x] > [total $mx]} { set mx $x } }
check "SUM" [lindex $got 0] [fmt [sumOf $all]]
check "MIN is a value of the table" [lindex $got 1] [fmt $mn]
check "MAX is a value of the table" [lindex $got 2] [fmt $mx]
# AVG
lassign [sumOf $all] sm ss
set n [llength $all]
check "AVG (the fractional month becomes days of 30 days)" [lindex [lindex [dict get [q "SELECT AVG($iv) FROM t"] rows] 0] 0] [mkitsql::ivFormat [mkitsql::ivScale [mkitsql::ivMake $sm $ss] [expr {1.0 / $n}]]]
# grouped
set byg [dict create]
foreach r $rows { dict lappend byg [lindex $r 1] [ivOf $r] }
set want {}
foreach g [lsort -integer [dict keys $byg]] {
    set l [dict get $byg $g] ; set a [lindex $l 0] ; set b [lindex $l 0]
    foreach x $l { if {[total $x] < [total $a]} { set a $x } ; if {[total $x] > [total $b]} { set b $x } }
    lappend want [list $g [fmt [sumOf $l]] [fmt $a] [fmt $b]]
}
check "grouped SUM/MIN/MAX" [dict get [q "SELECT g, SUM($iv), MIN($iv), MAX($iv) FROM t GROUP BY g ORDER BY g"] rows] $want
# DISTINCT: the same value counted once
set want {}
foreach g [lsort -integer [dict keys $byg]] {
    set seen {} ; foreach x [dict get $byg $g] { if {$x ni $seen} { lappend seen $x } }
    lappend want [list $g [fmt [sumOf $seen]]]
}
check "grouped SUM(DISTINCT)" [dict get [q "SELECT g, SUM(DISTINCT $iv) FROM t GROUP BY g ORDER BY g"] rows] $want
# window, running
set want {} ; set run {}
foreach r $rows { lappend run [ivOf $r] ; if {[lindex $r 0] <= 40} { lappend want [list [lindex $r 0] [fmt [sumOf $run]]] } }
check "running SUM" [dict get [q "SELECT id, SUM(iv) OVER (ORDER BY id) FROM (SELECT id, $iv AS iv FROM t) x WHERE id <= 40 ORDER BY id"] rows] [lrange $want 0 end]
check "no rows" [dict get [q "SELECT SUM($iv), AVG($iv), MIN($iv) FROM t WHERE id < 0"] rows] {{NULL NULL NULL}}
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "interval aggregates: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
