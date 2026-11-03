# plan.tcl -- query planner and executor for mkit-sql.
#
# compileQuery bq outerMaps  ->  plan id        (bound query -> executable plan)
# runPlan id outer           ->  list of tuples (NULL is the ::mkitsql::N sentinel)
#
# A tuple is a plain Tcl list.  Table scans produce  [loaded columns..., %cur]
# where %cur is the row's Metakit cursor path ("demo.people!3"); joins simply
# concatenate tuples.  WHERE conjuncts are pushed down to the scans they belong
# to, and equality conditions between the two sides of a join become hash joins.

namespace eval ::mkitsql {
    variable planSeq 0
    variable plans
    variable subCache
    variable ticks 0
    variable lookupSeq 0
    variable scanSeq 0
    variable scanCache
    variable scanRuns
    array set scanCache {}
    array set scanRuns {}
    variable lookupIdx
    array set lookupIdx {}
    variable wtable
    array set wtable {}
    variable maxRecursion 100000
    variable maxWorkRows 5000000
    variable chunk 2000
    variable capRows 0          ;# >0: stop scanning after this many rows (plain queries only)
    array set plans {}
    array set subCache {}
}

# ============================================================================
#  Helpers
# ============================================================================
proc ::mkitsql::splitAnd {e} {
    if {$e eq ""} { return {} }
    if {[lindex $e 0] eq "bin" && [lindex $e 1] eq "and"} {
        return [concat [splitAnd [lindex $e 2]] [splitAnd [lindex $e 3]]]
    }
    return [list $e]
}
proc ::mkitsql::joinAnd {exprs} {
    set r ""
    foreach e $exprs { if {$r eq ""} { set r $e } else { set r [list bin and $r $e] } }
    return $r
}
proc ::mkitsql::subset {a b} {
    foreach x $a { if {[lsearch -exact $b $x] < 0} { return 0 } }
    return 1
}

# Compile a list of bound conjuncts into one filter proc ("" if none).
proc ::mkitsql::compileFilter {exprs map outerMaps} {
    if {![llength $exprs]} { return "" }
    set ctx [dict create maps [concat [list $map] $outerMaps]]
    lassign [compileCond [joinAnd $exprs] $ctx] p t
    return $p
}

# Remove and return pool conjuncts whose local sources are a non-empty subset of `ids`.
proc ::mkitsql::takePool {stVar ids} {
    upvar 1 $stVar st
    set keep {} ; set take {}
    foreach c [dict get $st pool] {
        lassign $c e srcs
        if {[llength $srcs] && [subset $srcs $ids]} { lappend take $e } else { lappend keep $c }
    }
    dict set st pool $keep
    return $take
}

# ============================================================================
#  Compiling queries
# ============================================================================
proc ::mkitsql::compileQuery {bq outerMaps} {
    variable planSeq ; variable plans
    set id [incr planSeq]
    switch -- [dict get $bq kind] {
        select { set p [compileSelect $bq $outerMaps] }
        values {
            set procs {}
            foreach row [dict get $bq rows] {
                lassign [compileList $row [dict create maps [concat [list {}] $outerMaps]]] pr ts
                lappend procs $pr
            }
            set p [dict create kind values procs $procs]
        }
        setop {
            set p [dict create kind setop op [dict get $bq op] all [dict get $bq all] \
                left [compileQuery [dict get $bq left] $outerMaps] \
                right [compileQuery [dict get $bq right] $outerMaps]]
        }
        recursive {
            set p [dict create kind recursive all [dict get $bq all] tid [dict get $bq tid] \
                anchor [compileQuery [dict get $bq anchor] $outerMaps] \
                step [compileQuery [dict get $bq step] $outerMaps]]
        }
        query {
            set order {}
            foreach o [dict get $bq order] {
                lassign $o e dir nulls
                set idx [lindex $e 1]
                lappend order [list $idx $dir $nulls [lindex [dict get $bq outTypes] $idx]]
            }
            set p [dict create kind query body [compileQuery [dict get $bq body] $outerMaps] \
                order $order limit [dict get $bq limit] offset [dict get $bq offset]]
        }
        default { error "compileQuery: [dict get $bq kind]" }
    }
    dict set p names [dict get $bq outNames]
    dict set p types [dict get $bq outTypes]
    dict set p letters [dict get $bq outLetters]
    dict set p drill [dict get $bq outDrill]
    set plans($id) $p
    return $id
}

# ---- tuple layout of the sources -------------------------------------------
proc ::mkitsql::sourceLayout {s} {
    variable needed ; variable curCol
    set id [dict get $s id]
    set names {} ; set props {} ; set subs {}
    switch -- [dict get $s kind] {
        table - lateral {
            foreach c [dict get $s cols] {
                lassign $c n t l isSub
                if {![info exists needed($id,[string tolower $n])]} continue
                if {$isSub} { lappend subs $n } else { lappend props $n }
            }
            foreach n $props { lappend names [string tolower $n] }
            foreach n $subs { lappend names [string tolower $n] }
            lappend names [string tolower $curCol]
        }
        default {
            foreach c [dict get $s cols] { lappend names [string tolower [lindex $c 0]] }
        }
    }
    return [dict create names $names props $props subs $subs]
}

# ---- SELECT ----------------------------------------------------------------
proc ::mkitsql::compileSelect {bs outerMaps} {
    variable curCol
    set srcs [dict get $bs srcs]
    set lay [dict create]
    foreach s $srcs { dict set lay [dict get $s id] [sourceLayout $s] }

    # WHERE conjuncts and the sources each one touches
    set pool {}
    foreach e [splitAnd [dict get $bs where]] { lappend pool [list $e [localSrcs $e]] }
    set st [dict create lay $lay outer $outerMaps pool $pool]

    set from [dict get $bs from]
    if {$from eq ""} {
        set root [dict create plan {kind one} srcs {} width 0 map {}]
    } else {
        set root [cfNode $from 1 st]
    }
    set rootMap [dict get $root map]
    set rest {}
    foreach c [dict get $st pool] { lappend rest [lindex $c 0] }
    set whereProc [compileFilter $rest $rootMap $outerMaps]

    set p [dict create kind select src [dict get $root plan] where $whereProc \
        distinct [dict get $bs distinct]]

    # ---- aggregation
    set preCtx [dict create maps [concat [list $rootMap] $outerMaps]]
    set items [dict get $bs items]
    set having [dict get $bs having]
    set order [dict get $bs order]
    if {[dict get $bs isAgg]} {
        variable rwG ; variable rwAggs
        set rwG [dict get $bs group] ; set rwAggs {}
        set ng [llength $rwG]
        set items2 {}
        foreach e $items { lappend items2 [rwAgg $e] }
        set having2 [expr {$having eq "" ? "" : [rwAgg $having]}]
        set order2 {}
        foreach o $order {
            lassign $o e dir nulls
            lappend order2 [list [expr {[lindex $e 0] eq "outcol" ? $e : [rwAgg $e]}] $dir $nulls]
        }
        set aggNodes $rwAggs
        # compile group keys and aggregate arguments against the pre-aggregation tuple
        set gkey ""
        if {$ng} { lassign [compileList $rwG $preCtx] gkey _ }
        set argNodes {} ; set specs {}
        foreach a $aggNodes {
            lassign $a _ name distinct args
            set ai [llength $argNodes]
            if {[lindex $args 0 0] eq "star"} {
                lappend argNodes {lit int 1}
                set kind cstar
            } else {
                set a0 [lindex $args 0]
                set t0 [dryType $a0]
                if {$name in {SUM AVG} && $t0 eq "text"} { set a0 [list cast $a0 double] ; set t0 real }
                lappend argNodes $a0
                set kind [string tolower $name]
                if {$name eq "GROUP_CONCAT"} { set kind string_agg }
            }
            set sepIdx -1
            if {$name in {STRING_AGG GROUP_CONCAT} && [llength $args] > 1} {
                set sepIdx [llength $argNodes]
                lappend argNodes [lindex $args 1]
            }
            set sortKind [expr {[isNumType [expr {$kind in {min max} ? [dryType [lindex $args 0]] : "int"}]] ? "n" : "s"}]
            if {$kind in {sum avg min max} && [dryType [lindex $args 0]] eq "interval"} {
                fail "[string toupper $kind]() over intervals is not supported"
            }
            lappend specs [list $kind $distinct $ai $sepIdx $sortKind]
        }
        lassign [compileList $argNodes $preCtx] aargs _
        dict set p agg [dict create gkey $gkey ng $ng aargs $aargs specs $specs]
        set gmap {}
        set gj 0
        foreach g $rwG {
            if {[lindex $g 0] eq "ref" && [lindex $g 1] == 0} { dict set gmap [lindex $g 2],[string tolower [lindex $g 3]] $gj }
            incr gj
        }
        set ctx [dict create maps [concat [list $gmap] $outerMaps]]
        set items $items2 ; set having $having2 ; set order $order2
        set baseWidth [expr {$ng + [llength $aggNodes]}]
    } else {
        set ctx $preCtx
        set baseWidth [dict get $root width]
    }

    # ---- window functions: each call becomes a slot appended to the tuple
    set winSpecs {}
    set anyWin 0
    foreach e $items { if {[hasWin $e]} { set anyWin 1 } }
    foreach o $order { if {[lindex $o 0 0] ne "outcol" && [hasWin [lindex $o 0]]} { set anyWin 1 } }
    if {$anyWin} {
        variable rwWins ; variable rwBase
        set rwWins {} ; set rwBase $baseWidth
        set items2 {}
        foreach e $items { lappend items2 [rwWin $e] }
        set order2 {}
        foreach o $order {
            lassign $o e dir nulls
            lappend order2 [list [expr {[lindex $e 0] eq "outcol" ? $e : [rwWin $e]}] $dir $nulls]
        }
        set items $items2 ; set order $order2
        foreach w $rwWins { lappend winSpecs [compileWindow $w $ctx] }
        dict set p windows $winSpecs
    }
    if {$having ne ""} {
        lassign [compileCond $having $ctx] hp _
        dict set p having $hp
    }
    lassign [compileList $items $ctx] itemsProc itemTypes
    dict set p items $itemsProc
    dict set p itemTypes $itemTypes

    # ---- ORDER BY
    set ospec {} ; set ekeyNodes {}
    foreach o $order {
        lassign $o e dir nulls
        if {[lindex $e 0] eq "outcol"} {
            lappend ospec [list out [lindex $e 1] $dir $nulls [lindex [dict get $bs outTypes] [lindex $e 1]]]
        } else {
            lappend ospec [list key [llength $ekeyNodes] $dir $nulls [dryType $e]]
            lappend ekeyNodes $e
        }
    }
    if {[llength $ekeyNodes]} {
        lassign [compileList $ekeyNodes $ctx] okeys _
        dict set p okeys $okeys
    }
    dict set p order $ospec
    dict set p limit [dict get $bs limit]
    dict set p offset [dict get $bs offset]

    # ---- row ids for editable (plain, single-table) results
    set plain 0 ; set curPos -1 ; set source ""
    if {![dict get $bs isAgg] && ![dict get $bs distinct] && [llength $srcs] == 1 && !$anyWin} {
        set s [lindex $srcs 0]
        if {[dict exists $s path]} {
            set plain 1
            set curPos [dict get $rootMap [dict get $s id],[string tolower $curCol]]
            set source [dict get $s path]
        }
    }
    dict set p curPos $curPos
    dict set p plain $plain
    dict set p source $source
    # may the scan stop early once enough rows were produced?
    dict set p stoppable [expr {![dict get $bs isAgg] && ![dict get $bs distinct] && ![llength $ospec] && [llength $srcs] <= 1 && $whereProc eq "" && !$anyWin}]
    return $p
}

# ---- aggregate rewriting ---------------------------------------------------
proc ::mkitsql::rwAgg {node} {
    variable rwG ; variable rwAggs ; variable aggs
    set j [lsearch -exact $rwG $node]
    if {$j >= 0} { return [list slot $j [dryType $node]] }
    switch -- [lindex $node 0] {
        func {
            if {[lsearch -exact $aggs [lindex $node 1]] >= 0} {
                foreach a [lindex $node 3] {
                    if {[lindex $a 0] ne "star" && [hasAgg $a]} {
                        fail "Aggregate function calls cannot be nested"
                    }
                }
                set k [lsearch -exact $rwAggs $node]
                if {$k < 0} { set k [llength $rwAggs] ; lappend rwAggs $node }
                return [list slot [expr {[llength $rwG] + $k}] [aggType $node]]
            }
        }
        ref {
            if {[lindex $node 1] == 0} {
                fail "Column '[lindex $node 3]' must appear in the GROUP BY clause or be used in an aggregate function"
            }
            return $node
        }
        sub - exists {
            checkGroupedRefs [lindex $node 2]
            return $node
        }
        insub {
            checkGroupedRefs [lindex $node 4]
            return [lreplace $node 1 1 [rwAgg [lindex $node 1]]]
        }
        quant {
            checkGroupedRefs [lindex $node 5]
            return [lreplace $node 3 3 [rwAgg [lindex $node 3]]]
        }
        lit - slot { return $node }
    }
    return [mapChildren $node ::mkitsql::rwAgg]
}

# Can `a = b` be evaluated as a hash lookup?  Returns {a' b'} (numeric keys of
# different kinds are both converted to double) or "" when the types do not allow it.
proc ::mkitsql::keyPair {a b} {
    set ta [dryType $a] ; set tb [dryType $b]
    set na [isNumType $ta] ; set nb [isNumType $tb]
    if {$na && $nb} {
        if {$ta ne $tb && !($ta in {int bool} && $tb in {int bool})} {
            return [list [list cast $a double] [list cast $b double]]
        }
        return [list $a $b]
    }
    if {!$na && !$nb && $ta ne "null" && $tb ne "null"} { return [list $a $b] }
    return ""
}

# Does the expression refer to an enclosing query (level >= 1)?
proc ::mkitsql::hasOuterRef {node} {
    switch -- [lindex $node 0] {
        ref { return [expr {[lindex $node 1] >= 1}] }
        lit - slot { return 0 }
        sub - exists - insub { return 1 }
    }
    foreach c [exprChildren $node] { if {[hasOuterRef $c]} { return 1 } }
    return 0
}

# A subquery inside a grouped query may refer to the enclosing query's GROUP BY columns
# (they are read from the aggregated tuple), but not to ungrouped ones.
proc ::mkitsql::checkGroupedRefs {refs} {
    variable rwG
    foreach r $refs {
        lassign $r lvl sid name
        if {$lvl != 1} continue
        set ok 0
        foreach g $rwG {
            if {[lindex $g 0] eq "ref" && [lindex $g 1] == 0 && [lindex $g 2] == $sid && [string tolower [lindex $g 3]] eq $name} { set ok 1 }
        }
        if {!$ok} {
            fail "Column '$name' must appear in the GROUP BY clause or be used in an aggregate function (it is used inside a subquery)"
        }
    }
}

# ---- window rewriting ------------------------------------------------------
proc ::mkitsql::rwWin {node} {
    variable rwWins ; variable rwBase
    switch -- [lindex $node 0] {
        win {
            set k [lsearch -exact $rwWins $node]
            if {$k < 0} { set k [llength $rwWins] ; lappend rwWins $node }
            return [list slot [expr {$rwBase + $k}] [winType $node]]
        }
        lit - slot - ref - sub - exists { return $node }
    }
    return [mapChildren $node ::mkitsql::rwWin]
}

# Compile one window call into a plan dict for runWindows.
proc ::mkitsql::compileWindow {w ctx} {
    lassign $w _ name distinct args spec
    set part [dict get $spec partition]
    set ords [dict get $spec order]
    set exprs $part
    set otypes {} ; set dirs {} ; set nulls {}
    foreach o $ords {
        lappend exprs [lindex $o 0]
        lappend otypes [dryType [lindex $o 0]]
        lappend dirs [lindex $o 1] ; lappend nulls [lindex $o 2]
    }
    set argNodes {}
    set sortKind s
    if {[lindex $args 0 0] ne "star"} {
        foreach a $args { lappend argNodes $a }
        if {$name in {SUM AVG} && [dryType [lindex $argNodes 0]] eq "text"} {
            lset argNodes 0 [list cast [lindex $argNodes 0] double]
        }
        if {[llength $argNodes]} { set sortKind [expr {[isNumType [dryType [lindex $argNodes 0]]] ? "n" : "s"}] }
    }
    lassign [compileList [concat $exprs $argNodes] $ctx] wp _
    return [dict create fn $name np [llength $part] no [llength $ords] nargs [llength $argNodes] \
        star [expr {[lindex $args 0 0] eq "star"}] proc $wp dirs $dirs nulls $nulls otypes $otypes \
        frame [dict get $spec frame] sortKind $sortKind]
}

# ---- FROM tree -------------------------------------------------------------
# Each returns a dict:  plan  srcs (ids, in tuple order)  width  map
proc ::mkitsql::cfNode {t pushable stVar} {
    upvar 1 $stVar st
    switch -- [lindex $t 0] {
        src  { return [cfLeaf [lindex $t 1] $pushable st] }
        join { return [cfJoin $t $pushable st] }
    }
    error "cfNode: [lindex $t 0]"
}

proc ::mkitsql::cfLeaf {s pushable stVar {latmap {}}} {
    upvar 1 $stVar st
    variable curCol
    set id [dict get $s id]
    set lay [dict get $st lay $id]
    set map {} ; set i 0
    foreach n [dict get $lay names] { dict set map $id,$n $i ; incr i }
    set width $i
    set filter "" ; set lookup {} ; set sfilter "" ; set dfilter ""
    if {$pushable} {
        set own [takePool st [list $id]]
        if {[dict get $s kind] eq "table"} {
            # `inner = <expression of an enclosing query>` becomes a hash lookup, built once per statement
            variable lookupSeq
            set kl {} ; set kr {} ; set rest {}
            foreach c $own {
                set done 0
                if {[lindex $c 0] eq "bin" && [lindex $c 1] eq "="} {
                    foreach {a b} [list [lindex $c 2] [lindex $c 3] [lindex $c 3] [lindex $c 2]] {
                        if {[localSrcs $a] eq [list $id] && ![hasOuterRef $a] && [localSrcs $b] eq {} && [hasOuterRef $b]} {
                            set kp [keyPair $a $b]
                            if {$kp ne ""} { lappend kl [lindex $kp 0] ; lappend kr [lindex $kp 1] ; set done 1 ; break }
                        }
                    }
                }
                if {!$done} { lappend rest $c }
            }
            if {[llength $kl]} {
                set outer [dict get $st outer]
                lassign [compileList $kl [dict create maps [concat [list $map] $outer]]] ikey _
                lassign [compileList $kr [dict create maps [concat [list {}] $outer]]] okey _
                set lookup [dict create lid [incr lookupSeq] ikey $ikey okey $okey]
                set own $rest
            }
        }
        set filter [compileFilter $own $map [dict get $st outer]]
        # conjuncts that do not depend on an enclosing query can be applied once and cached
        set stat {} ; set dyn {}
        foreach c $own { if {[hasOuterRef $c]} { lappend dyn $c } else { lappend stat $c } }
        set sfilter [compileFilter $stat $map [dict get $st outer]]
        set dfilter [compileFilter $dyn $map [dict get $st outer]]
    }
    if {!$pushable} { set sfilter "" ; set dfilter "" }
    switch -- [dict get $s kind] {
        table {
            variable scanSeq
            set plan [dict create kind scan path [dict get $s path] props [dict get $lay props] \
                subs [dict get $lay subs] filter $filter sfilter $sfilter dfilter $dfilter lookup $lookup sid [incr scanSeq]]
        }
        lateral {
            if {[dict exists $s plevel]} {
                # the subview belongs to a row of an enclosing query: find that row's cursor in the outer tuple
                set pl [dict get $s plevel]
                set om [lindex [dict get $st outer] [expr {$pl - 1}]]
                set key [dict get $s parent],[string tolower $curCol]
                if {![dict exists $om $key]} { fail "Cannot read the subview '[dict get $s sub]' of the enclosing query here" }
                set plan [dict create kind lateralouter level $pl pos [dict get $om $key] sub [dict get $s sub] \
                    props [dict get $lay props] subs [dict get $lay subs] filter $filter]
            } else {
                set plan [dict create kind lateral parent [dict get $s parent] sub [dict get $s sub] \
                    props [dict get $lay props] subs [dict get $lay subs] filter $filter]
            }
        }
        derived {
            if {[dict exists $s lateralq] && [dict get $s lateralq]} {
                set plan [dict create kind latderived \
                    sub [compileQuery [dict get $s bq] [concat [list $latmap] [dict get $st outer]]] filter $filter]
            } else {
                set om [expr {[dict exists $s outerok] && [dict get $s outerok] ? [dict get $st outer] : {}}]
                set plan [dict create kind derived sub [compileQuery [dict get $s bq] $om] filter $filter]
            }
        }
        wref {
            set plan [dict create kind wref tid [dict get $s tid] filter $filter]
        }
        info {
            set plan [dict create kind info which [dict get $s which] filter $filter]
        }
        default { error "cfLeaf: [dict get $s kind]" }
    }
    return [dict create plan $plan srcs [list $id] width $width map $map]
}

proc ::mkitsql::cfJoin {t pushable stVar} {
    upvar 1 $stVar st
    variable curCol
    lassign $t _ type l r on
    set outer [dict get $st outer]
    set lres [cfNode $l [expr {$pushable && $type in {inner cross left}}] st]
    if {[lindex $r 0] eq "src" && [dict exists [lindex $r 1] lateralq] && [dict get [lindex $r 1] lateralq]} {
        if {$type in {right full}} { fail "RIGHT / FULL JOIN is not supported with LATERAL" }
        set rres [cfLeaf [lindex $r 1] [expr {$pushable && $type in {inner cross}}] st [dict get $lres map]]
    } else {
        set rres [cfNode $r [expr {$pushable && $type in {inner cross right}}] st]
    }
    set lsrcs [dict get $lres srcs] ; set rsrcs [dict get $rres srcs]
    set wl [dict get $lres width] ; set wr [dict get $rres width]
    set lmap [dict get $lres map] ; set rmap [dict get $rres map]
    set cmap $lmap
    dict for {k v} $rmap { dict set cmap $k [expr {$v + $wl}] }

    set rplan [dict get $rres plan]
    set latDerived [expr {[dict get $rplan kind] eq "latderived"}]
    set lateral [expr {[dict get $rplan kind] eq "lateral" || $latDerived}]
    set curPos -1
    if {$lateral && !$latDerived} {
        set parent [dict get $rplan parent]
        set key $parent,[string tolower $curCol]
        if {![dict exists $lmap $key]} { fail "A subview can only be joined to the table that owns it" }
        set curPos [dict get $lmap $key]
        if {$type in {right full}} { fail "RIGHT / FULL JOIN is not supported with a subview" }
    }

    set conds [splitAnd $on]
    set post {}
    if {$pushable && $type in {inner cross}} {
        set conds [concat $conds [takePool st [concat $lsrcs $rsrcs]]]
    }
    # equality conditions between the two sides become hash-join keys
    set lkeys {} ; set rkeys {} ; set resid {}
    foreach c $conds {
        set done 0
        if {!$lateral && [lindex $c 0] eq "bin" && [lindex $c 1] eq "="} {
            set a [lindex $c 2] ; set b [lindex $c 3]
            set sa [localSrcs $a] ; set sb [localSrcs $b]
            if {[llength $sa] && [llength $sb]} {
                if {[subset $sa $lsrcs] && [subset $sb $rsrcs]} { set kl $a ; set kr $b ; set ok 1
                } elseif {[subset $sb $lsrcs] && [subset $sa $rsrcs]} { set kl $b ; set kr $a ; set ok 1
                } else { set ok 0 }
                if {$ok} {
                    set tl [dryType $kl] ; set tr [dryType $kr]
                    set nl [isNumType $tl] ; set nr [isNumType $tr]
                    if {$nl && $nr} {
                        if {$tl ne $tr && !($tl in {int bool} && $tr in {int bool})} {
                            set kl [list cast $kl double] ; set kr [list cast $kr double]
                        }
                        lappend lkeys $kl ; lappend rkeys $kr ; set done 1
                    } elseif {!$nl && !$nr && $tl ne "null" && $tr ne "null"} {
                        lappend lkeys $kl ; lappend rkeys $kr ; set done 1
                    }
                }
            }
        }
        if {!$done} { lappend resid $c }
    }
    set lkp "" ; set rkp ""
    if {[llength $lkeys]} {
        lassign [compileList $lkeys [dict create maps [concat [list $lmap] $outer]]] lkp _
        lassign [compileList $rkeys [dict create maps [concat [list $rmap] $outer]]] rkp _
    }
    set residProc [compileFilter $resid $cmap $outer]
    if {$pushable && $type in {left right full}} {
        set post [takePool st [concat $lsrcs $rsrcs]]
    }
    set postProc [compileFilter $post $cmap $outer]

    set plan [dict create kind join type $type left [dict get $lres plan] right $rplan \
        wl $wl wr $wr lkey $lkp rkey $rkp resid $residProc post $postProc \
        lateral $lateral latderived $latDerived curPos $curPos]
    return [dict create plan $plan srcs [concat $lsrcs $rsrcs] width [expr {$wl + $wr}] map $cmap]
}

# ============================================================================
#  Running plans
# ============================================================================
proc ::mkitsql::runPlan {id outer} {
    variable plans
    set p $plans($id)
    switch -- [dict get $p kind] {
        select { return [lindex [runSelect $p $outer] 0] }
        values {
            set out {}
            foreach pr [dict get $p procs] { lappend out [$pr {} $outer] }
            return $out
        }
        setop { return [runSetop $p $outer] }
        recursive { return [runRecursive $p $outer] }
        query {
            set rows [runPlan [dict get $p body] $outer]
            set order [dict get $p order]
            if {[llength $order]} {
                set spec {}
                foreach o $order { lappend spec [list out [lindex $o 0] [lindex $o 1] [lindex $o 2] [lindex $o 3]] }
                set recs {}
                foreach r $rows {
                    set rec {}
                    foreach o $order { lappend rec [lindex $r [lindex $o 0]] }
                    lappend rec $r
                    lappend recs $rec
                }
                set recs [sortRecs $recs $spec]
                set rows {}
                set n [llength $order]
                foreach rec $recs { lappend rows [lindex $rec $n] }
            }
            return [applyLimit $rows [dict get $p limit] [dict get $p offset]]
        }
    }
}

# Iterate a recursive CTE: each round runs the recursive part against the rows the
# previous round produced.  UNION (not ALL) drops rows already seen, which is also
# what makes cyclic data terminate.
proc ::mkitsql::runRecursive {p outer {budget 0}} {
    variable wtable ; variable maxRecursion ; variable cancel ; variable progressHook ; variable maxWorkRows
    set tid [dict get $p tid] ; set all [dict get $p all]
    set rows [runPlan [dict get $p anchor] $outer]
    if {!$all} {
        set seen [dict create] ; set uniq {}
        foreach r $rows { if {![dict exists $seen $r]} { dict set seen $r 1 ; lappend uniq $r } }
        set rows $uniq
    }
    set work $rows
    set iter 0
    while {[llength $work] && !($budget > 0 && [llength $rows] >= $budget)} {
        if {[incr iter] > $maxRecursion} {
            catch {unset wtable($tid)}
            fail "Recursive query stopped after $maxRecursion rounds.  Add a stop condition (WHERE ...) or raise ::mkitsql::maxRecursion"
        }
        if {$cancel} { fail "Cancelled" }
        if {$progressHook ne ""} { {*}$progressHook }
        set wtable($tid) $work
        set new [runPlan [dict get $p step] $outer]
        if {!$all} {
            set fresh {}
            foreach r $new { if {![dict exists $seen $r]} { dict set seen $r 1 ; lappend fresh $r } }
            set new $fresh
        }
        foreach r $new { lappend rows $r }
        if {[llength $rows] > $maxWorkRows} {
            catch {unset wtable($tid)}
            fail "Recursive query produced more than $maxWorkRows rows.  Add a stop condition (WHERE ...)"
        }
        set work $new
    }
    catch {unset wtable($tid)}
    if {$budget > 0 && [llength $rows] > $budget} { set rows [lrange $rows 0 [expr {$budget - 1}]] }
    return $rows
}

proc ::mkitsql::applyLimit {rows limit offset} {
    if {$offset ne "" && $offset > 0} { set rows [lrange $rows $offset end] }
    if {$limit ne ""} { set rows [lrange $rows 0 [expr {$limit - 1}]] }
    return $rows
}

proc ::mkitsql::runSetop {p outer} {
    set l [runPlan [dict get $p left] $outer]
    set r [runPlan [dict get $p right] $outer]
    set all [dict get $p all]
    switch -- [dict get $p op] {
        union {
            if {$all} { return [concat $l $r] }
            set seen [dict create] ; set out {}
            foreach row [concat $l $r] {
                if {![dict exists $seen $row]} { dict set seen $row 1 ; lappend out $row }
            }
            return $out
        }
        intersect {
            set cnt [dict create]
            foreach row $r { dict incr cnt $row }
            set out {} ; set seen [dict create]
            foreach row $l {
                if {$all} {
                    if {[dict exists $cnt $row] && [dict get $cnt $row] > 0} {
                        dict incr cnt $row -1 ; lappend out $row
                    }
                } else {
                    if {[dict exists $cnt $row] && ![dict exists $seen $row]} { dict set seen $row 1 ; lappend out $row }
                }
            }
            return $out
        }
        except {
            set cnt [dict create]
            foreach row $r { dict incr cnt $row }
            set out {} ; set seen [dict create]
            foreach row $l {
                if {$all} {
                    if {[dict exists $cnt $row] && [dict get $cnt $row] > 0} {
                        dict incr cnt $row -1
                    } else { lappend out $row }
                } else {
                    if {![dict exists $cnt $row] && ![dict exists $seen $row]} { dict set seen $row 1 ; lappend out $row }
                }
            }
            return $out
        }
    }
}

# ---- SELECT ----------------------------------------------------------------
# Returns {rows rowids}
proc ::mkitsql::runSelect {p outer} {
    variable capRows
    set stoppable [dict get $p stoppable]
    set stop 0
    if {$stoppable} {
        set limit [dict get $p limit] ; set offset [dict get $p offset]
        if {$limit ne ""} {
            set stop [expr {$limit + ($offset eq "" ? 0 : $offset)}]
        } elseif {$capRows > 0} {
            set stop $capRows
        }
    }
    set rows [runSrc [dict get $p src] $outer $stop]
    set w [dict get $p where]
    if {$w ne ""} {
        set keep {}
        foreach r $rows { if {[$w $r $outer] eq "1"} { lappend keep $r } }
        set rows $keep
    }
    if {[dict exists $p agg]} {
        set rows [runAgg [dict get $p agg] $rows $outer]
        if {[dict exists $p having]} {
            set h [dict get $p having] ; set keep {}
            foreach r $rows { if {[$h $r $outer] eq "1"} { lappend keep $r } }
            set rows $keep
        }
    }
    if {[dict exists $p windows]} { set rows [runWindows [dict get $p windows] $rows $outer] }
    set items [dict get $p items]
    set order [dict get $p order]
    set norder [llength $order]
    set okeys [expr {[dict exists $p okeys] ? [dict get $p okeys] : ""}]
    set curPos [dict get $p curPos]
    set distinct [dict get $p distinct]
    set seen [dict create]
    set recs {}
    foreach r $rows {
        set out [$items $r $outer]
        if {$distinct} {
            if {[dict exists $seen $out]} continue
            dict set seen $out 1
        }
        if {$norder} {
            if {$okeys ne ""} { set ek [$okeys $r $outer] } else { set ek {} }
            set rec {}
            foreach o $order {
                lassign $o kind idx
                if {$kind eq "out"} { lappend rec [lindex $out $idx] } else { lappend rec [lindex $ek $idx] }
            }
            lappend rec $out
            if {$curPos >= 0} { lappend rec [lindex $r $curPos] }
            lappend recs $rec
        } else {
            if {$curPos >= 0} { lappend recs [list $out [lindex $r $curPos]] } else { lappend recs [list $out] }
        }
    }
    if {$norder} { set recs [sortRecs $recs $order] }
    set ofs $norder
    set recs [applyLimit $recs [dict get $p limit] [dict get $p offset]]
    set outRows {} ; set ids {}
    foreach rec $recs {
        lappend outRows [lindex $rec $ofs]
        if {$curPos >= 0} {
            lappend ids [lindex [split [lindex $rec [expr {$ofs + 1}]] !] end]
        }
    }
    return [list $outRows $ids]
}

# ---- sorting ---------------------------------------------------------------
# recs: each {key1 .. keyN payload ...}.  spec: list of {kind idx dir nulls type}.
# Multi-key sort = successive stable sorts from the last key to the first.
proc ::mkitsql::sortRecs {recs spec} {
    variable N
    for {set k [expr {[llength $spec] - 1}]} {$k >= 0} {incr k -1} {
        lassign [lindex $spec $k] kind idx dir nulls type
        set nullRecs {} ; set valRecs {}
        foreach r $recs {
            if {[lindex $r $k] eq $N} { lappend nullRecs $r } else { lappend valRecs $r }
        }
        if {$type eq "interval"} {
            # sort by length of time, not by the internal text form
            set tmp {}
            foreach r $valRecs { lset r $k [ivTotal [lindex $r $k]] ; lappend tmp $r }
            set valRecs $tmp
            set type real
        }
        set mode [expr {$type in {int} ? "-integer" : ($type in {real bool} ? "-real" : "-ascii")}]
        set dirflag [expr {$dir eq "desc" ? "-decreasing" : "-increasing"}]
        if {[catch {lsort $mode $dirflag -index $k $valRecs} sorted]} {
            set sorted [lsort -real $dirflag -index $k $valRecs]
        }
        # NULLs sort as the smallest value unless NULLS FIRST / LAST says otherwise
        if {$nulls eq ""} { set nullsFirst [expr {$dir ne "desc"}] } else { set nullsFirst [expr {$nulls eq "first"}] }
        if {$nullsFirst} { set recs [concat $nullRecs $sorted] } else { set recs [concat $sorted $nullRecs] }
    }
    return $recs
}

# ---- sources ---------------------------------------------------------------
proc ::mkitsql::runSrc {node outer stop} {
    switch -- [dict get $node kind] {
        one { return [list {}] }
        scan { return [scanPath [dict get $node path] $node $outer $stop] }
        lateralouter {
            set cur [lindex [lindex $outer [expr {[dict get $node level] - 1}]] [dict get $node pos]]
            return [scanPath $cur.[dict get $node sub] $node $outer $stop]
        }
        derived {
            variable plans
            set sub [dict get $node sub]
            # a plain LIMIT over a recursive query is a row budget: stop iterating once it is met
            if {$stop > 0 && [dict get $node filter] eq "" && [dict get $plans($sub) kind] eq "recursive"} {
                return [runRecursive $plans($sub) $outer $stop]
            }
            return [filterRows [runPlan $sub $outer] [dict get $node filter] $outer]
        }
        info { return [filterRows [infoRows [dict get $node which]] [dict get $node filter] $outer] }
        wref {
            variable wtable
            return [filterRows $wtable([dict get $node tid]) [dict get $node filter] $outer]
        }
        join { return [runJoin $node $outer] }
    }
    if {[dict get $node kind] eq "latderived"} { fail "A LATERAL subquery must come after another FROM item (use JOIN LATERAL or a comma)" }
    error "runSrc: [dict get $node kind]"
}

proc ::mkitsql::filterRows {rows filter outer} {
    if {$filter eq ""} { return $rows }
    set out {}
    foreach r $rows { if {[$filter $r $outer] eq "1"} { lappend out $r } }
    return $out
}

# Scan a Metakit view (or subview) and return tuples  [props.. subcounts.. cur]
proc ::mkitsql::scanPath {path node outer stop} {
    variable chunk ; variable progressHook ; variable cancel ; variable lookupIdx ; variable N ; variable scanCache ; variable scanRuns
    set props [dict get $node props] ; set subs [dict get $node subs]
    set filter [dict get $node filter]
    # A scan that runs again and again (a correlated subquery that cannot use a hash lookup)
    # reads the table from Metakit once and filters the cached rows afterwards.
    if {$stop == 0 && [dict exists $node sid] && ![dict exists $node nocache] && [dict get $node lookup] eq ""} {
        set sid [dict get $node sid]
        if {![info exists scanRuns($sid)]} { set scanRuns($sid) 0 }
        if {[incr scanRuns($sid)] >= 3 && [::store::size $path] <= 300000} {
            if {![info exists scanCache($sid)]} {
                set scanCache($sid) [scanPath $path [dict replace $node filter [dict get $node sfilter] nocache 1] {} 0]
            }
            return [filterRows $scanCache($sid) [dict get $node dfilter] $outer]
        }
    }
    if {[dict exists $node lookup] && [dict get $node lookup] ne ""} {
        set lk [dict get $node lookup]
        set lid [dict get $lk lid]
        set okey [[dict get $lk okey] {} $outer]
        if {[lsearch -exact $okey $N] >= 0} { return {} }
        if {![info exists lookupIdx($lid)]} {
            set ikey [dict get $lk ikey]
            set idx [dict create]
            set raw [dict replace $node filter [dict get $node sfilter] lookup {} nocache 1]
            foreach t [scanPath $path $raw {} 0] {
                set k [$ikey $t {}]
                if {[lsearch -exact $k $N] < 0} { dict lappend idx $k $t }
            }
            set lookupIdx($lid) $idx
        }
        if {![dict exists $lookupIdx($lid) $okey]} { return {} }
        return [filterRows [dict get $lookupIdx($lid) $okey] [dict get $node dfilter] $outer]
    }
    set n [::store::size $path]
    set out {}
    set cnt 0
    for {set first 0} {$first < $n} {incr first $chunk} {
        if {$cancel} { fail "Cancelled" }
        if {$progressHook ne ""} { {*}$progressHook }
        set data [::store::rows $path $props $first $chunk]
        set i $first
        foreach r $data {
            foreach sp $subs { lappend r [::store::subSize $path $i $sp] }
            lappend r $path!$i
            incr i
            if {$filter ne "" && [$filter $r $outer] ne "1"} continue
            lappend out $r
            if {$stop > 0 && [incr cnt] >= $stop} { return $out }
        }
    }
    return $out
}

# ---- joins -----------------------------------------------------------------
proc ::mkitsql::runJoin {node outer} {
    variable N
    set type [dict get $node type]
    set wl [dict get $node wl] ; set wr [dict get $node wr]
    set resid [dict get $node resid] ; set post [dict get $node post]
    set L [runSrc [dict get $node left] $outer 0]
    set nullR [lrepeat $wr $N] ; set nullL [lrepeat $wl $N]
    set out {}

    if {[dict get $node lateral]} {
        set rn [dict get $node right]
        set latDerived [dict get $node latderived]
        if {!$latDerived} { set curPos [dict get $node curPos] ; set sub [dict get $rn sub] }
        foreach l $L {
            if {$latDerived} {
                # LATERAL (subquery): run it once per left row, with that row visible as outer level 1
                set R [filterRows [runPlan [dict get $rn sub] [linsert $outer 0 $l]] [dict get $rn filter] $outer]
            } else {
                set path [lindex $l $curPos].$sub
                set R [scanPath $path $rn $outer 0]
            }
            set hit 0
            foreach r $R {
                set t [list {*}$l {*}$r]
                if {$resid ne "" && [$resid $t $outer] ne "1"} continue
                lappend out $t ; set hit 1
            }
            if {!$hit && $type eq "left"} { lappend out [list {*}$l {*}$nullR] }
        }
    } else {
        set R [runSrc [dict get $node right] $outer 0]
        set lkey [dict get $node lkey]
        set matchedR [dict create]
        if {$lkey ne ""} {
            # hash join: build on the right
            set rkey [dict get $node rkey]
            set ht [dict create]
            set ri 0
            foreach r $R {
                set k [$rkey $r $outer]
                if {[lsearch -exact $k $N] < 0} { dict lappend ht $k $ri }
                incr ri
            }
            set Ra [dict create] ; set ri 0
            foreach r $R { dict set Ra $ri $r ; incr ri }
            foreach l $L {
                set k [$lkey $l $outer]
                set hit 0
                if {[lsearch -exact $k $N] < 0 && [dict exists $ht $k]} {
                    foreach ri [dict get $ht $k] {
                        set t [list {*}$l {*}[dict get $Ra $ri]]
                        if {$resid ne "" && [$resid $t $outer] ne "1"} continue
                        lappend out $t ; set hit 1
                        dict set matchedR $ri 1
                    }
                }
                if {!$hit && $type in {left full}} { lappend out [list {*}$l {*}$nullR] }
            }
        } else {
            set Rl [llength $R]
            foreach l $L {
                set hit 0 ; set ri 0
                foreach r $R {
                    set t [list {*}$l {*}$r]
                    if {$resid eq "" || [$resid $t $outer] eq "1"} {
                        lappend out $t ; set hit 1 ; dict set matchedR $ri 1
                    }
                    incr ri
                }
                if {!$hit && $type in {left full}} { lappend out [list {*}$l {*}$nullR] }
            }
        }
        if {$type in {right full}} {
            set ri 0
            foreach r $R {
                if {![dict exists $matchedR $ri]} { lappend out [list {*}$nullL {*}$r] }
                incr ri
            }
        }
    }
    if {$post ne ""} { set out [filterRows $out $post $outer] }
    return $out
}

# ---- aggregation -----------------------------------------------------------
proc ::mkitsql::runAgg {a rows outer} {
    variable N
    set ng [dict get $a ng] ; set gkey [dict get $a gkey]
    set aargs [dict get $a aargs] ; set specs [dict get $a specs]
    set nagg [llength $specs]
    set order {}                    ;# group keys in first-seen order
    set gidx [dict create]
    array set S {} ; array set C {} ; array set SEEN {}
    foreach r $rows {
        if {$ng} { set key [$gkey $r $outer] } else { set key "" }
        if {![dict exists $gidx $key]} {
            set gi [llength $order]
            dict set gidx $key $gi ; lappend order $key
            initGroup S C $gi $specs
        } else { set gi [dict get $gidx $key] }
        set args [$aargs $r $outer]
        set k 0
        foreach spec $specs {
            lassign $spec kind distinct ai sepIdx sortKind
            set v [lindex $args $ai]
            switch -- $kind {
                cstar { incr S($gi,$k) }
                default {
                    if {$v eq $N} { incr k ; continue }
                    if {$distinct} {
                        if {[info exists SEEN($gi,$k,$v)]} { incr k ; continue }
                        set SEEN($gi,$k,$v) 1
                    }
                    switch -- $kind {
                        count { incr S($gi,$k) }
                        sum   { if {$S($gi,$k) eq $N} { set S($gi,$k) $v } else { set S($gi,$k) [expr {$S($gi,$k) + $v}] } }
                        avg   { set S($gi,$k) [expr {$S($gi,$k) + $v}] ; incr C($gi,$k) }
                        min {
                            if {$S($gi,$k) eq $N} { set S($gi,$k) $v } elseif {
                                $sortKind eq "n" ? $v < $S($gi,$k) : [string compare $v $S($gi,$k)] < 0} { set S($gi,$k) $v }
                        }
                        max {
                            if {$S($gi,$k) eq $N} { set S($gi,$k) $v } elseif {
                                $sortKind eq "n" ? $v > $S($gi,$k) : [string compare $v $S($gi,$k)] > 0} { set S($gi,$k) $v }
                        }
                        string_agg {
                            lappend S($gi,$k) $v
                            if {$sepIdx >= 0 && ![info exists C($gi,$k)]} { set C($gi,$k) [lindex $args $sepIdx] }
                        }
                    }
                }
            }
            incr k
        }
    }
    # no GROUP BY: always one group, even over zero rows
    if {$ng == 0 && ![llength $order]} {
        lappend order "" ; initGroup S C 0 $specs
    }
    set out {}
    set gi 0
    foreach key $order {
        set t $key
        set k 0
        foreach spec $specs {
            set kind [lindex $spec 0]
            switch -- $kind {
                avg {
                    if {$C($gi,$k) == 0} { lappend t $N } else { lappend t [expr {double($S($gi,$k)) / $C($gi,$k)}] }
                }
                string_agg {
                    if {![llength $S($gi,$k)]} { lappend t $N } else {
                        if {[info exists C($gi,$k)]} { set sep $C($gi,$k) } else { set sep "," }
                        lappend t [join $S($gi,$k) $sep]
                    }
                }
                default { lappend t $S($gi,$k) }
            }
            incr k
        }
        lappend out $t
        incr gi
    }
    return $out
}
proc ::mkitsql::initGroup {sv cv gi specs} {
    upvar 1 $sv S $cv C
    set k 0
    foreach spec $specs {
        switch -- [lindex $spec 0] {
            cstar - count { set S($gi,$k) 0 }
            avg { set S($gi,$k) 0 ; set C($gi,$k) 0 }
            string_agg { set S($gi,$k) {} }
            default { set S($gi,$k) $::mkitsql::N }
        }
        incr k
    }
}

# ---- information_schema ----------------------------------------------------
proc ::mkitsql::letterSqlName {l} {
    switch -- $l {
        S { return VARCHAR } I { return INTEGER } L { return BIGINT } F { return REAL }
        D { return "DOUBLE PRECISION" } B { return BLOB } V { return TABLE }
    }
    return $l
}
proc ::mkitsql::infoRows {which} {
    set rows {}
    foreach tag [::store::tags] {
        foreach v [::store::views $tag] {
            if {$which eq "tables"} {
                lappend rows [list $tag $v "BASE TABLE" [::store::size $tag.$v]]
            } else {
                set i 0
                foreach c [::store::layout $tag.$v] {
                    lappend rows [list $tag $v [lindex $c 0] [incr i] [letterSqlName [lindex $c 1]] [lindex $c 1]]
                }
            }
        }
    }
    return $rows
}

# ============================================================================
#  Subquery runtime
# ============================================================================
proc ::mkitsql::tick {} {
    variable ticks ; variable cancel ; variable progressHook
    if {[incr ticks] % 100 == 0} {
        if {$cancel} { fail "Cancelled" }
        if {$progressHook ne ""} { {*}$progressHook }
    }
}
proc ::mkitsql::rt::scalar {id r0 outer} {
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    if {!$corr && [info exists ::mkitsql::subCache($id)]} { return $::mkitsql::subCache($id) }
    set rows [::mkitsql::runPlan $id [linsert $outer 0 $r0]]
    switch -- [llength $rows] {
        0 { set v $::mkitsql::N }
        1 { set v [lindex $rows 0 0] }
        default { ::mkitsql::fail "More than one row returned by a subquery used as an expression" }
    }
    if {!$corr} { set ::mkitsql::subCache($id) $v }
    return $v
}
proc ::mkitsql::rt::exists {id r0 outer} {
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    if {!$corr && [info exists ::mkitsql::subCache($id)]} { return $::mkitsql::subCache($id) }
    set v [expr {[llength [::mkitsql::runPlan $id [linsert $outer 0 $r0]]] > 0}]
    if {!$corr} { set ::mkitsql::subCache($id) $v }
    return $v
}
# v op ANY / ALL (subquery)
proc ::mkitsql::rt::quant {id nm kind ck v r0 outer} {
    set N $::mkitsql::N
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    if {!$corr && [info exists ::mkitsql::subCache($id)]} {
        set vals $::mkitsql::subCache($id)
    } else {
        set vals {}
        foreach r [::mkitsql::runPlan $id [linsert $outer 0 $r0]] { lappend vals [lindex $r 0] }
        if {!$corr} { set ::mkitsql::subCache($id) $vals }
    }
    set cmp ::mkitsql::rt::${nm}_$ck
    set sawNull 0
    foreach x $vals {
        set c [$cmp $v $x]
        if {$c eq $N} { set sawNull 1 ; continue }
        if {$kind eq "any"} { if {$c} { return 1 } } else { if {!$c} { return 0 } }
    }
    if {$sawNull} { return $N }
    return [expr {$kind eq "all"}]
}

proc ::mkitsql::rt::insub {id v r0 outer} {
    set N $::mkitsql::N
    if {$v eq $N} {
        # NULL IN (empty set) is false, otherwise unknown
        set rows [::mkitsql::runPlan $id [linsert $outer 0 $r0]]
        return [expr {[llength $rows] ? $N : 0}]
    }
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    if {!$corr && [info exists ::mkitsql::subCache($id)]} {
        lassign $::mkitsql::subCache($id) set hasNull
    } else {
        set rows [::mkitsql::runPlan $id [linsert $outer 0 $r0]]
        set set [dict create] ; set hasNull 0
        foreach r $rows {
            set x [lindex $r 0]
            if {$x eq $N} { set hasNull 1 } else { dict set set $x 1 }
        }
        if {!$corr} { set ::mkitsql::subCache($id) [list $set $hasNull] }
    }
    if {[dict exists $set $v]} { return 1 }
    # numeric equality such as 2 vs 2.0
    if {[string is double -strict $v]} {
        dict for {k _} $set { if {[string is double -strict $k] && $k == $v} { return 1 } }
    }
    return [expr {$hasNull ? $N : 0}]
}
