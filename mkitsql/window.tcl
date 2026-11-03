# window.tcl -- window-function runtime for mkit-sql.
#
# runWindows specs rows outer  ->  rows, each extended by one value per window call.
# Rows keep their original order; ORDER BY inside OVER only orders each partition.

namespace eval ::mkitsql {}

proc ::mkitsql::runWindows {specs rows outer} {
    variable cancel
    set n [llength $rows]
    if {$n == 0} { return {} }
    set cols {}
    foreach w $specs {
        if {$cancel} { fail "Cancelled" }
        lappend cols [evalWindow $w $rows $outer $n]
    }
    set out {}
    for {set i 0} {$i < $n} {incr i} {
        set r [lindex $rows $i]
        foreach c $cols { lappend r [lindex $c $i] }
        lappend out $r
    }
    return $out
}

proc ::mkitsql::evalWindow {w rows outer n} {
    variable N
    set np [dict get $w np] ; set no [dict get $w no] ; set pr [dict get $w proc]
    set parts [dict create]
    set args {} ; set oks {}
    set i 0
    foreach r $rows {
        set ev [$pr $r $outer]
        lappend oks [lrange $ev $np [expr {$np + $no - 1}]]
        lappend args [lrange $ev [expr {$np + $no}] end]
        dict lappend parts [lrange $ev 0 [expr {$np - 1}]] $i
        incr i
    }
    set res [lrepeat $n $N]
    # sort specification for the ORDER BY inside OVER
    set sspec {}
    set k 0
    foreach d [dict get $w dirs] nl [dict get $w nulls] ot [dict get $w otypes] {
        lappend sspec [list key $k $d $nl $ot]
        incr k
    }
    dict for {key idxs} $parts {
        if {$no > 0} {
            set recs {}
            foreach i $idxs { lappend recs [concat [lindex $oks $i] [list $i]] }
            set recs [sortRecs $recs $sspec]
            set idxs {}
            foreach rec $recs { lappend idxs [lindex $rec end] }
        }
        set pok {} ; set pargs {}
        foreach i $idxs { lappend pok [lindex $oks $i] ; lappend pargs [lindex $args $i] }
        set vals [winPartition $w $pok $pargs]
        set j 0
        foreach i $idxs { lset res $i [lindex $vals $j] ; incr j }
    }
    return $res
}

# Values for one sorted partition.  pok = order-key lists, pargs = argument lists.
proc ::mkitsql::winPartition {w pok pargs} {
    variable N
    set fn [dict get $w fn]
    set m [llength $pok]
    # peer groups: consecutive rows with equal ORDER BY keys
    set gid {} ; set gs {} ; set ge {}
    set g -1 ; set prev "\u0000first"
    for {set j 0} {$j < $m} {incr j} {
        set k [lindex $pok $j]
        if {$j == 0 || $k ne $prev} { incr g ; lappend gs $j ; lappend ge $j } else { lset ge $g $j }
        lappend gid $g
        set prev $k
    }
    set out {}
    switch -- $fn {
        ROW_NUMBER { for {set j 0} {$j < $m} {incr j} { lappend out [expr {$j + 1}] } ; return $out }
        RANK       { for {set j 0} {$j < $m} {incr j} { lappend out [expr {[lindex $gs [lindex $gid $j]] + 1}] } ; return $out }
        DENSE_RANK { for {set j 0} {$j < $m} {incr j} { lappend out [expr {[lindex $gid $j] + 1}] } ; return $out }
        PERCENT_RANK {
            for {set j 0} {$j < $m} {incr j} {
                lappend out [expr {$m == 1 ? 0.0 : double([lindex $gs [lindex $gid $j]]) / ($m - 1)}]
            }
            return $out
        }
        CUME_DIST {
            for {set j 0} {$j < $m} {incr j} { lappend out [expr {double([lindex $ge [lindex $gid $j]] + 1) / $m}] }
            return $out
        }
        NTILE {
            set nb [lindex $pargs 0 0]
            if {$nb eq $N || ![string is integer -strict $nb] || $nb < 1} { fail "NTILE needs a positive whole number" }
            set q [expr {$m / $nb}] ; set rem [expr {$m % $nb}]
            set j 0
            for {set b 1} {$b <= $nb && $j < $m} {incr b} {
                set size [expr {$q + ($b <= $rem ? 1 : 0)}]
                for {set c 0} {$c < $size} {incr c} { lappend out $b ; incr j }
            }
            return $out
        }
        LAG - LEAD {
            for {set j 0} {$j < $m} {incr j} {
                set a [lindex $pargs $j]
                if {[llength $a] > 1} { set off [lindex $a 1] } else { set off 1 }
                if {[llength $a] > 2} { set def [lindex $a 2] } else { set def $N }
                if {$off eq $N || ![string is integer -strict $off] || $off < 0} { fail "LAG / LEAD offset must be a non-negative whole number" }
                set t [expr {$fn eq "LAG" ? $j - $off : $j + $off}]
                if {$t >= 0 && $t < $m} { lappend out [lindex $pargs $t 0] } else { lappend out $def }
            }
            return $out
        }
    }
    # ---- frame based functions
    lassign [frameBounds $w $m $pok $gid $gs $ge] LO HI
    switch -- $fn {
        FIRST_VALUE - LAST_VALUE {
            for {set j 0} {$j < $m} {incr j} {
                set lo [lindex $LO $j] ; set hi [lindex $HI $j]
                if {$lo > $hi} { lappend out $N } elseif {$fn eq "FIRST_VALUE"} { lappend out [lindex $pargs $lo 0] } else { lappend out [lindex $pargs $hi 0] }
            }
            return $out
        }
        NTH_VALUE {
            for {set j 0} {$j < $m} {incr j} {
                set nth [lindex $pargs $j 1]
                if {$nth eq $N || ![string is integer -strict $nth] || $nth < 1} { fail "NTH_VALUE needs a positive whole number" }
                set t [expr {[lindex $LO $j] + $nth - 1}]
                if {$t <= [lindex $HI $j]} { lappend out [lindex $pargs $t 0] } else { lappend out $N }
            }
            return $out
        }
    }
    return [winAggregate $w $m $pargs $LO $HI]
}

# Frame start / end positions (inclusive) for every row of a partition.
proc ::mkitsql::frameBounds {w m pok gid gs ge} {
    set frame [dict get $w frame]
    set hasOrder [expr {[dict get $w no] > 0}]
    if {![llength $frame]} {
        # default frame: with ORDER BY up to the last peer, otherwise the whole partition
        set frame [expr {$hasOrder ? {range {unbounded_preceding {}} {current {}}} : {rows {unbounded_preceding {}} {unbounded_following {}}}}]
    }
    lassign $frame mode b1 b2
    set LO {} ; set HI {}
    set ng [llength $gs]
    set simpleRange [expr {$mode eq "range" && [lindex $b1 0] ni {preceding following} && [lindex $b2 0] ni {preceding following}}]
    if {$simpleRange} { set mode groups }
    for {set j 0} {$j < $m} {incr j} {
        switch -- $mode {
            rows {
                set lo [boundPos rows $b1 start $j $m {} {} {}]
                set hi [boundPos rows $b2 end $j $m {} {} {}]
            }
            groups {
                set g [lindex $gid $j]
                set lo [boundGroup $b1 start $g $ng $gs $ge $m]
                set hi [boundGroup $b2 end $g $ng $gs $ge $m]
            }
            range {
                lassign [rangeBounds $w $b1 $b2 $j $m $pok $gid $gs $ge] lo hi
            }
        }
        if {$lo < 0} { set lo 0 }
        if {$hi > $m - 1} { set hi [expr {$m - 1}] }
        lappend LO $lo ; lappend HI $hi
    }
    return [list $LO $HI]
}

proc ::mkitsql::boundPos {mode b side j m a b2 c} {
    lassign $b kind off
    switch -- $kind {
        unbounded_preceding { return 0 }
        unbounded_following { return [expr {$m - 1}] }
        current   { return $j }
        preceding { return [expr {$j - $off}] }
        following { return [expr {$j + $off}] }
    }
}
proc ::mkitsql::boundGroup {b side g ng gs ge m} {
    lassign $b kind off
    switch -- $kind {
        unbounded_preceding { return 0 }
        unbounded_following { return [expr {$m - 1}] }
        current { return [expr {$side eq "start" ? [lindex $gs $g] : [lindex $ge $g]}] }
        preceding {
            set t [expr {$g - $off}]
            if {$t < 0} { return [expr {$side eq "start" ? 0 : -1}] }
            return [expr {$side eq "start" ? [lindex $gs $t] : [lindex $ge $t]}]
        }
        following {
            set t [expr {$g + $off}]
            if {$t >= $ng} { return [expr {$side eq "start" ? $m : $m - 1}] }
            return [expr {$side eq "start" ? [lindex $gs $t] : [lindex $ge $t]}]
        }
    }
}

# RANGE frame with a numeric offset on the single ORDER BY key.
proc ::mkitsql::rangeBounds {w b1 b2 j m pok gid gs ge} {
    variable N
    set desc [expr {[lindex [dict get $w dirs] 0] eq "desc"}]
    set v [lindex $pok $j 0]
    set g [lindex $gid $j]
    set ends {}
    foreach {b side} [list $b1 start $b2 end] {
        lassign $b kind off
        switch -- $kind {
            unbounded_preceding { lappend ends 0 }
            unbounded_following { lappend ends [expr {$m - 1}] }
            current { lappend ends [expr {$side eq "start" ? [lindex $gs $g] : [lindex $ge $g]}] }
            default {
                if {$v eq $N} { lappend ends [expr {$side eq "start" ? [lindex $gs $g] : [lindex $ge $g]}] ; continue }
                # value the boundary sits at
                set sign [expr {($kind eq "preceding") != $desc ? -1 : 1}]
                set bv [expr {$v + $sign * $off}]
                set found [expr {$side eq "start" ? $m : -1}]
                for {set p 0} {$p < $m} {incr p} {
                    set pv [lindex $pok $p 0]
                    if {$pv eq $N} continue
                    set ok [expr {$desc ? $pv <= $bv : $pv >= $bv}]
                    if {$side eq "start"} {
                        if {$ok} { set found $p ; break }
                    } else {
                        set inside [expr {$desc ? $pv >= $bv : $pv <= $bv}]
                        if {$inside} { set found $p }
                    }
                }
                lappend ends $found
            }
        }
    }
    return $ends
}

# ---- aggregates over a frame ----------------------------------------------
proc ::mkitsql::winInit {fn} {
    variable N
    switch -- $fn {
        COUNT { return 0 }
        SUM - AVG { return [list 0 0] }
        MIN - MAX { return $N }
        default { return {} }
    }
}
proc ::mkitsql::winStep {fn sk st v sep} {
    variable N
    if {$fn eq "COUNT"} { return [expr {$v eq $N ? $st : $st + 1}] }
    if {$v eq $N} { return $st }
    switch -- $fn {
        SUM - AVG { return [list [expr {[lindex $st 0] + 1}] [expr {[lindex $st 1] + $v}]] }
        MIN {
            if {$st eq $N} { return $v }
            if {$sk eq "n" ? $v < $st : [string compare $v $st] < 0} { return $v }
            return $st
        }
        MAX {
            if {$st eq $N} { return $v }
            if {$sk eq "n" ? $v > $st : [string compare $v $st] > 0} { return $v }
            return $st
        }
        default { lappend st $v ; return $st }
    }
}
proc ::mkitsql::winFinal {fn st sep} {
    variable N
    switch -- $fn {
        COUNT - MIN - MAX {
            if {$fn eq "COUNT"} { return $st }
            return $st
        }
        SUM { return [expr {[lindex $st 0] == 0 ? $N : [lindex $st 1]}] }
        AVG { return [expr {[lindex $st 0] == 0 ? $N : double([lindex $st 1]) / [lindex $st 0]}] }
        default { if {[llength $st]} { return [join $st $sep] } ; return $N }
    }
}

proc ::mkitsql::winAggregate {w m pargs LO HI} {
    variable N
    set fn [dict get $w fn] ; set sk [dict get $w sortKind] ; set star [dict get $w star]
    if {$fn eq "GROUP_CONCAT"} { set fn STRING_AGG }
    set out {}
    set plo -1 ; set phi -2 ; set st [winInit $fn]
    for {set j 0} {$j < $m} {incr j} {
        set lo [lindex $LO $j] ; set hi [lindex $HI $j]
        if {[llength [lindex $pargs $j]] > 1} { set sep [lindex $pargs $j 1] } else { set sep "," }
        if {$lo > $hi} {
            lappend out [winFinal $fn [winInit $fn] $sep]
            continue
        }
        # extend the running state when the frame only grew at the end; otherwise rebuild
        if {$lo == $plo && $hi >= $phi} {
            set from [expr {$phi + 1}]
        } else {
            set st [winInit $fn] ; set from $lo
        }
        for {set p $from} {$p <= $hi} {incr p} {
            set v [expr {$star ? 1 : [lindex $pargs $p 0]}]
            set st [winStep $fn $sk $st $v $sep]
        }
        set plo $lo ; set phi $hi
        lappend out [winFinal $fn $st $sep]
    }
    return $out
}
