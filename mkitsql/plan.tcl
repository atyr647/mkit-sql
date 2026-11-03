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
    variable maxSetRows 5000000
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
    foreach tag [::mkitsql::db::tags] {
        foreach v [::mkitsql::db::views $tag] {
            if {$which eq "tables"} {
                lappend rows [list [cleanText $tag] [cleanText $v] "BASE TABLE" [::mkitsql::db::size $tag.$v]]
            } else {
                set i 0
                foreach c [::mkitsql::db::layout $tag.$v] {
                    lappend rows [list [cleanText $tag] [cleanText $v] [cleanText [lindex $c 0]] [incr i] [letterSqlName [lindex $c 1]] [lindex $c 1]]
                }
            }
        }
    }
    return $rows
}

# ============================================================================
#  Subquery runtime   (all of these stop reading as soon as they know the answer)
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
    set rows [::mkitsql::collectPlan $id [linsert $outer 0 $r0] 2]
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
    set v [expr {[llength [::mkitsql::collectPlan $id [linsert $outer 0 $r0] 1]] > 0}]
    if {!$corr} { set ::mkitsql::subCache($id) $v }
    return $v
}
# the distinct values of a one-column subquery as {dict hasNull}; refuses sets too big to hold
proc ::mkitsql::valueSet {id r0 outer} {
    variable S
    set c [newId] ; set S($c,set) [dict create] ; set S($c,null) 0
    streamPlan $id [linsert $outer 0 $r0] [list ::mkitsql::setSink $c]
    set r [list $S($c,set) $S($c,null)]
    array unset S $c,*
    return $r
}
proc ::mkitsql::setSink {c chunk} {
    variable S ; variable N ; variable maxSetRows
    foreach row $chunk {
        set x [lindex $row 0]
        if {$x eq $N} { set S($c,null) 1 } else { dict set S($c,set) $x 1 }
    }
    if {[dict size $S($c,set)] > $maxSetRows} {
        fail "A subquery used with IN / ANY / ALL returned more than $maxSetRows distinct values.  Rewrite it as a JOIN, or raise ::mkitsql::maxSetRows"
    }
    return 0
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
        foreach r [::mkitsql::collectPlan $id [linsert $outer 0 $r0]] { lappend vals [lindex $r 0] }
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
        set rows [::mkitsql::collectPlan $id [linsert $outer 0 $r0] 1]
        return [expr {[llength $rows] ? $N : 0}]
    }
    set corr $::mkitsql::planCorr($id)
    if {$corr} { ::mkitsql::tick }
    if {!$corr && [info exists ::mkitsql::subCache($id)]} {
        lassign $::mkitsql::subCache($id) set hasNull
    } else {
        lassign [::mkitsql::valueSet $id $r0 $outer] set hasNull
        if {!$corr} { set ::mkitsql::subCache($id) [list $set $hasNull] }
    }
    if {[dict exists $set $v]} { return 1 }
    # numeric equality such as 2 vs 2.0
    if {[string is double -strict $v]} {
        dict for {k _} $set { if {[string is double -strict $k] && $k == $v} { return 1 } }
    }
    return [expr {$hasNull ? $N : 0}]
}
