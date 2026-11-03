# EXCLUDE (CURRENT ROW / GROUP / TIES / NO OTHERS), DISTINCT in window aggregates and IGNORE NULLS, checked against a brute-force
# reference that works row by row from the definitions (no frames cleverness).   tclsh tests/window_ext.tcl [rounds] [seed]
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set rounds [expr {$argc > 0 ? [lindex $argv 0] : 120}]
expr {srand([expr {$argc > 1 ? [lindex $argv 1] : 5}])}
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_wx_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 400]\n   want: [string range $want 0 400]" }
}
proc q {sql} { mkitsql::run $sql $::db }
q "CREATE TABLE t (id INT, g INT, o INT, v INT)"
# reference -------------------------------------------------------------------------------------------------------------------
# rows: list of {id g o v} with v possibly "N" (NULL).  Returns the expected value per id for one window call.
proc refFrame {part j mode lo hi} {   ;# part sorted by o then id; positions in the frame of row j (ROWS or GROUPS)
    set m [llength $part]
    if {$mode eq "rows"} {
        set a [expr {$lo eq "U" ? 0 : $j - $lo}] ; set b [expr {$hi eq "U" ? $m - 1 : $j + $hi}]
    } else {   ;# groups: peers = equal o
        set oj [lindex $part $j 2] ; set os {}
        foreach r $part { if {[lindex $r 2] ni $os} { lappend os [lindex $r 2] } }
        set gj [lsearch -exact $os $oj]
        set ga [expr {$lo eq "U" ? 0 : $gj - $lo}] ; set gb [expr {$hi eq "U" ? [llength $os] - 1 : $gj + $hi}]
        set a $m ; set b -1
        for {set p 0} {$p < $m} {incr p} {
            set gp [lsearch -exact $os [lindex $part $p 2]]
            if {$gp >= $ga && $gp <= $gb} { if {$p < $a} { set a $p } ; if {$p > $b} { set b $p } }
        }
    }
    set out {}
    for {set p [expr {max($a, 0)}]} {$p <= [expr {min($b, $m - 1)}]} {incr p} { lappend out $p }
    return $out
}
proc refExclude {part j pos excl mode} {
    # peers: rows with the same ORDER BY value; the ROWS queries order by (o, id), which makes every row its own peer
    set out {}
    foreach p $pos {
        set peer [expr {$mode eq "rows" ? $p == $j : [lindex $part $p 2] == [lindex $part $j 2]}]
        switch -- $excl {
            current { if {$p == $j} continue }
            group   { if {$peer} continue }
            ties    { if {$peer && $p != $j} continue }
        }
        lappend out $p
    }
    return $out
}
proc agg {fn vals distinct} {
    set v2 {}
    foreach x $vals { if {$x ne "N"} { if {!$distinct || $x ni $v2} { lappend v2 $x } } }
    switch -- $fn {
        COUNT { return [llength $v2] }
        SUM   { if {![llength $v2]} { return NULL } ; set s 0 ; foreach x $v2 { incr s $x } ; return $s }
        MIN   { if {![llength $v2]} { return NULL } ; return [tcl::mathfunc::min {*}$v2] }
        MAX   { if {![llength $v2]} { return NULL } ; return [tcl::mathfunc::max {*}$v2] }
    }
}
for {set round 0} {$round < $rounds} {incr round} {
    q "DELETE FROM t"
    set n [expr {3 + int(rand() * 12)}] ; set rows {}
    for {set i 1} {$i <= $n} {incr i} {
        set g [expr {int(rand() * 2)}] ; set o [expr {int(rand() * 4)}]
        set v [expr {rand() < 0.3 ? "N" : int(rand() * 5)}]
        lappend rows [list $i $g $o $v]
        q "INSERT INTO t VALUES ($i, $g, $o, [expr {$v eq "N" ? "-1" : $v}])"
    }
    # NULLs come from NULLIF(v, -1) in a derived table
    set src "(SELECT id, g, o, NULLIF(v, -1) AS v FROM t) x"
    # partitions, sorted by o then id
    set parts {}
    foreach r $rows { dict lappend parts [lindex $r 1] $r }
    set sorted [dict create]
    dict for {g rs} $parts { dict set sorted $g [lsort -command {apply {{a b} { set c [expr {[lindex $a 2] - [lindex $b 2]}] ; if {$c} { return $c } ; expr {[lindex $a 0] - [lindex $b 0]} }}} $rs] }
    foreach mode {rows groups} {
        foreach {lo hi} {U U 1 1 2 0 0 1 U 0 0 U} {
            foreach excl {"" current group ties} {
                foreach fn {COUNT SUM MIN MAX} {
                    foreach distinct {0 1} {
                        set lt [expr {$lo eq "U" ? "UNBOUNDED PRECEDING" : "$lo PRECEDING"}]
                        set ht [expr {$hi eq "U" ? "UNBOUNDED FOLLOWING" : "$hi FOLLOWING"}]
                        if {$mode eq "rows" && $lo eq "0"} { set lt "CURRENT ROW" }
                        if {$mode eq "rows" && $hi eq "0"} { set ht "CURRENT ROW" }
                        if {$mode eq "groups" && $lo eq "0"} { set lt "CURRENT ROW" }
                        if {$mode eq "groups" && $hi eq "0"} { set ht "CURRENT ROW" }
                        set ex [expr {$excl eq "" ? "" : " EXCLUDE [expr {$excl eq {current} ? {CURRENT ROW} : [string toupper $excl]}]"}]
                        set sql "SELECT id, ${fn}([expr {$distinct ? {DISTINCT } : {}}]v) OVER (PARTITION BY g ORDER BY o, id [string toupper $mode] BETWEEN $lt AND $ht$ex) FROM $src ORDER BY id"
                        # the reference keeps GROUPS peers by o only; ORDER BY o, id makes every row its own peer for ROWS, so for GROUPS use o alone
                        if {$mode eq "groups"} { set sql [string map {"ORDER BY o, id GROUPS" "ORDER BY o GROUPS"} $sql] }
                        set want {}
                        dict for {g part} $sorted {
                            for {set j 0} {$j < [llength $part]} {incr j} {
                                set pos [refExclude $part $j [refFrame $part $j $mode $lo $hi] $excl $mode]
                                set vals {} ; foreach p $pos { lappend vals [lindex $part $p 3] }
                                lappend want [list [lindex $part $j 0] [agg $fn $vals $distinct]]
                            }
                        }
                        set want [lsort -integer -index 0 $want]
                        if {$distinct && $fn in {MIN MAX}} { } 
                        if {[catch {set got [dict get [q $sql] rows]} err]} { set got "ERROR $err" }
                        check "round $round: $sql" $got $want
                        if {[info exists ::env(WX_DUMP)] && !$distinct} { set ch [open $::env(WX_DUMP) a] ; set rl {} ; foreach r $rows { lappend rl [join $r ,] } ; puts $ch [list [join $rl ";"] $sql $got] ; close $ch }
                    }
                }
            }
        }
    }
    # IGNORE NULLS
    set parts2 $sorted
    foreach fn {FIRST_VALUE LAST_VALUE} {
        foreach ign {0 1} {
            set sql "SELECT id, ${fn}(v) [expr {$ign ? {IGNORE NULLS} : {RESPECT NULLS}}] OVER (PARTITION BY g ORDER BY o, id ROWS BETWEEN 1 PRECEDING AND 2 FOLLOWING) FROM $src ORDER BY id"
            set want {}
            dict for {g part} $sorted {
                for {set j 0} {$j < [llength $part]} {incr j} {
                    set pos [refFrame $part $j rows 1 2] ; set vals {}
                    foreach p $pos { set x [lindex $part $p 3] ; if {!$ign || $x ne "N"} { lappend vals $x } }
                    set x [expr {$fn eq "FIRST_VALUE" ? [lindex $vals 0] : [lindex $vals end]}]
                    lappend want [list [lindex $part $j 0] [expr {$x eq "" || $x eq "N" ? "NULL" : $x}]]
                }
            }
            check "round $round: $sql" [dict get [q $sql] rows] [lsort -integer -index 0 $want]
        }
    }
    foreach fn {LAG LEAD} {
        foreach off {1 2} {
            set sql "SELECT id, ${fn}(v, $off, -9) IGNORE NULLS OVER (PARTITION BY g ORDER BY o, id) FROM $src ORDER BY id"
            set want {}
            dict for {g part} $sorted {
                set m [llength $part]
                for {set j 0} {$j < $m} {incr j} {
                    set step [expr {$fn eq "LAG" ? -1 : 1}] ; set t $j ; set left $off
                    while {$left > 0} { incr t $step ; if {$t < 0 || $t >= $m} break ; if {[lindex $part $t 3] ne "N"} { incr left -1 } }
                    set x [expr {$t >= 0 && $t < $m ? [lindex $part $t 3] : -9}]
                    lappend want [list [lindex $part $j 0] [expr {$x eq "N" ? "NULL" : $x}]]
                }
            }
            check "round $round: $sql" [dict get [q $sql] rows] [lsort -integer -index 0 $want]
        }
    }
}
# error paths
foreach {sql frag} {
    {SELECT SUM(v) OVER (ORDER BY id EXCLUDE CURRENT ROW) FROM t} "EXCLUDE needs a frame"
    {SELECT ROW_NUMBER() IGNORE NULLS OVER (ORDER BY id) FROM t} "IGNORE NULLS is only allowed"
    {SELECT LAG(v) IGNORE NULLS FROM t} "needs an OVER"
    {SELECT COUNT(DISTINCT *) OVER () FROM t} ""
    {SELECT FIRST_VALUE(DISTINCT v) OVER () FROM t} "only allowed in aggregate"
} {
    set r [catch {q $sql} err]
    check "error: $sql" [expr {$r && [string match "*$frag*" $err]}] 1
}
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "window extensions: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
