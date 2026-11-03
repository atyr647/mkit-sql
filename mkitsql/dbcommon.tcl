# dbcommon.tcl -- storage operations built only from the primitives every storage layer provides (layout, size,
# restructure, ...), so db.tcl (standalone) and db_studio.tcl (MK Studio's ::store) behave identically.  Loaded before either.
namespace eval ::mkitsql::db { variable tmpSeq 0 }

# Rename and/or retype a top-level scalar column, keeping its data.  Metakit identifies a property by
# (name, type), so the new column is added, filled from the old one (coercing numbers) and the old one
# dropped; the rebuilt column ends up last.
proc ::mkitsql::db::rebuildColumn {path oldName newName newType} {
    set layout [layout $path]
    set oldType ""
    foreach c $layout { if {[lindex $c 0] eq $oldName} { set oldType [lindex $c 1] } }
    if {$oldType eq "" || $oldType eq "V"} { error "'$oldName' is not a scalar column." }
    if {$newName ne $oldName} {
        foreach c $layout { if {[lindex $c 0] eq $newName} { error "Column '$newName' already exists." } }
    }
    # a retype keeps the column's name with another type: Metakit cannot do that (see dbcheck.tcl)
    if {$newName eq $oldName && $newType ne $oldType} {
        error "Metakit cannot change the type of column '$oldName' in place; copy the table with CREATE TABLE ... AS SELECT CAST($oldName AS ...)."
    }
    variable tmpSeq
    set tmp __mks_tmp_[pid]_[incr tmpSeq]            ;# never reused: a name that came back with another type would clash
    if {[string first ! $path] < 0} {
        lassign [split $path .] gtag gview
        # the final layout must not give any name a type it has not had: checked BEFORE anything changes
        set final {}
        foreach c $layout { if {[lindex $c 0] ne $oldName} { lappend final $c } }
        typeGuard $gtag $gview [concat $final [list [list $newName $newType {}]]]
    }
    set base {}
    foreach c $layout { if {[lindex $c 0] ne $oldName} { lappend base $c } }
    set T [list $tmp $newType {}]
    set Nw [list $newName $newType {}]
    restructure $path [concat $layout [list $T]]
    copyColumn $path $oldName $tmp $newType
    restructure $path [concat $base [list $T]]
    restructure $path [concat $base [list $T $Nw]]
    copyColumn $path $tmp $newName $newType
    restructure $path [concat $base [list $Nw]]
}
proc ::mkitsql::db::copyColumn {path from to type} {
    set n [size $path]
    for {set i 0} {$i < $n} {incr i} {
        set v [mk::get $path!$i $from]
        switch -- $type {
            I - L { if {![string is integer -strict $v]} { set v [expr {[string is double -strict $v] ? int($v) : 0}] } }
            F - D { if {![string is double -strict $v]} { set v 0 } }
        }
        mk::set $path!$i $to $v
    }
}

# ---- reading rows (shared by both back ends) ------------------------------------------------------------
# `count` rows from `first`, as lists of values in the order of `props` (scalar properties only).
proc ::mkitsql::db::rows {path props first count} {
    set out {}
    set n [mk::view size $path]
    set last [expr {min($n, $first + $count) - 1}]
    set np [llength $props]
    if {$::mkitsql::listBug} {
        # Tcl 8.5 / 8.6.3 damage the string form of a list whose first element is '#...' text with two or more ] or ", and
        # that is the list a multi-property mk::get returns: read one property at a time (see ::mkitsql::rt::sk)
        for {set i $first} {$i <= $last} {incr i} {
            set row {}
            foreach p $props { lappend row [mk::get $path!$i $p] }
            lappend out [::mkitsql::rt::sk $row]
        }
        return $out
    }
    for {set i $first} {$i <= $last} {incr i} {
        if {$np == 0} {
            lappend out {}
        } elseif {$np == 1} {
            lappend out [list [mk::get $path!$i [lindex $props 0]]]     ;# a single property comes back unwrapped
        } else {
            lappend out [mk::get $path!$i {*}$props]
        }
    }
    return $out
}


# the given rows (indices) in the order of `props`, like `rows`
proc ::mkitsql::db::rowsAt {path props indices} {
    set out {}
    set np [llength $props]
    if {$np == 0} { foreach i $indices { lappend out {} } ; return $out }
    if {$::mkitsql::listBug} {
        foreach i $indices {
            set row {}
            foreach p $props { lappend row [mk::get $path!$i $p] }
            lappend out [::mkitsql::rt::sk $row]
        }
        return $out
    }
    if {$np == 1} {
        set p [lindex $props 0]
        foreach i $indices { lappend out [list [mk::get $path!$i $p]] }
        return $out
    }
    foreach i $indices { lappend out [mk::get $path!$i {*}$props] }
    return $out
}


