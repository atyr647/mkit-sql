# db.tcl -- the storage layer of mkit-sql: the only code (with db_studio.tcl) that talks to Mk4tcl.
#
# The engine calls ::mkitsql::db::* and nothing else.  Two implementations of that interface exist:
#
#   db.tcl         (this file) STANDALONE: talks to Mk4tcl (mk::*) directly.  mkit-sql needs nothing
#                  from MK Studio.  This is the default.
#   db_studio.tcl  an adapter that forwards to MK Studio's ::store package when that is loaded, so both
#                  share one set of open files inside MK Studio.
#
# Vocabulary
#   tag     name Mk4tcl knows an open datafile by            (e.g. "demo")
#   path    a Metakit view path                              (e.g. "demo.people", "demo.people!3.skills")
#   layout  list of {name type sub} triples; type is one of S I L F D B V; for V (subview) `sub` is a
#           nested layout, else {}.
#
# Files are opened with -nocommit: nothing reaches the disk until `commit`, and closing never saves.
# Written for Tcl 8.5 and 8.6.

namespace eval ::mkitsql::db {
    variable tags {}         ;# open tags, in open order
    variable file            ;# tag -> absolute path
    variable ro              ;# tag -> read-only flag
    variable dirty           ;# tag -> number of uncommitted changes
    array set file {} ; array set ro {} ; array set dirty {}
}

# ---- files ---------------------------------------------------------------------------------
proc ::mkitsql::db::available {} { expr {[llength [info commands ::mk::file]] > 0} }

proc ::mkitsql::db::makeTag {path} {
    variable tags
    set base [file rootname [file tail $path]]
    regsub -all {[^A-Za-z0-9_]} $base _ base
    if {$base eq "" || [string is digit [string index $base 0]]} { set base db_$base }
    set tag $base ; set n 1
    while {[lsearch -exact $tags $tag] >= 0} { set tag ${base}_[incr n] }
    return $tag
}
proc ::mkitsql::db::tags {} { variable tags ; return $tags }
proc ::mkitsql::db::path {tag}     { variable file ; return $file($tag) }
proc ::mkitsql::db::readonly {tag} { variable ro   ; return $ro($tag) }
proc ::mkitsql::db::dirty {tag}    { variable dirty ; return $dirty($tag) }
proc ::mkitsql::db::touch {tag}    { variable dirty ; incr dirty($tag) }
proc ::mkitsql::db::touchPath {path} { touch [lindex [split $path .!] 0] }

# Open (or with -create, create) a datafile; returns its tag.  Options: -create -readonly
proc ::mkitsql::db::openFile {path args} {
    variable tags ; variable file ; variable ro ; variable dirty
    set create 0 ; set readonly 0
    foreach a $args {
        switch -- $a { -create {set create 1} -readonly {set readonly 1} default { error "unknown option $a" } }
    }
    set path [::file normalize $path]
    foreach t $tags { if {$file($t) eq $path} { error "File is already open as '$t'." } }
    if {!$create && ![::file exists $path]} { error "File not found: $path" }
    set tag [makeTag $path]
    set opts {-nocommit}
    if {$readonly} { lappend opts -readonly }
    if {[catch {mk::file open $tag $path {*}$opts}]} {
        # a very old Mk4tcl without -nocommit
        mk::file open $tag $path {*}[expr {$readonly ? {-readonly} : {}}]
    }
    lappend tags $tag
    set file($tag) $path ; set ro($tag) $readonly ; set dirty($tag) 0
    return $tag
}
proc ::mkitsql::db::closeFile {tag} {
    variable tags ; variable file ; variable ro ; variable dirty
    catch {mk::file close $tag}
    set i [lsearch -exact $tags $tag]
    if {$i >= 0} { set tags [lreplace $tags $i $i] }
    unset -nocomplain file($tag) ro($tag) dirty($tag)
}
proc ::mkitsql::db::commit {tag} {
    variable dirty
    mk::file commit $tag
    set dirty($tag) 0
}
# Discard uncommitted work (newer Mk4tcl has `mk::file rollback`; otherwise reopen, which is safe with -nocommit).
proc ::mkitsql::db::rollback {tag} {
    variable dirty ; variable file ; variable ro
    if {[catch {mk::file rollback $tag}]} {
        set opts {-nocommit}
        if {$ro($tag)} { lappend opts -readonly }
        mk::file close $tag
        mk::file open $tag $file($tag) {*}$opts
    }
    set dirty($tag) 0
}

# ---- structure ------------------------------------------------------------------------------
# Metakit keeps listing a view after `mk::view delete` until the next commit; a deleted view has no layout.
proc ::mkitsql::db::views {tag} {
    set out {}
    foreach v [mk::file views $tag] {
        if {![catch {mk::view layout $tag.$v}]} { lappend out $v }
    }
    return [lsort -dictionary $out]
}
proc ::mkitsql::db::hasView {tag name} { expr {[lsearch -exact [views $tag] $name] >= 0} }

# "name:S age:I {addr {street:S city:S}} note"  ->  {{name S {}} {age I {}} {addr V {...}} {note S {}}}
proc ::mkitsql::db::parseLayout {spec} {
    set out {}
    foreach el $spec {
        if {[llength $el] == 2} {
            lappend out [list [lindex $el 0] V [parseLayout [lindex $el 1]]]
        } else {
            set i [string first : $el]
            if {$i < 0} {
                lappend out [list $el S {}]
            } else {
                lappend out [list [string range $el 0 [expr {$i-1}]] [string toupper [string range $el [expr {$i+1}] end]] {}]
            }
        }
    }
    return $out
}
proc ::mkitsql::db::formatLayout {layout} {
    set parts {}
    foreach col $layout {
        lassign $col n t sub
        if {$t eq "V"} { lappend parts [list $n [formatLayout $sub]] } else { lappend parts $n:$t }
    }
    return $parts
}
proc ::mkitsql::db::layout {path} { parseLayout [mk::view layout $path] }
proc ::mkitsql::db::size   {path} { mk::view size $path }
proc ::mkitsql::db::subSize {path idx prop} { mk::view size $path!$idx.$prop }

# ---- reading rows ---------------------------------------------------------------------------
# `count` rows from `first`, as lists of values in the order of `props` (scalar properties only).
proc ::mkitsql::db::rows {path props first count} {
    set out {}
    set n [mk::view size $path]
    set last [expr {min($n, $first + $count) - 1}]
    set np [llength $props]
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

# ---- writing rows ---------------------------------------------------------------------------
proc ::mkitsql::db::appendRow {path props values} {
    set args {}
    foreach p $props v $values { lappend args $p $v }
    set cur [mk::row append $path {*}$args]
    touchPath $path
    return [lindex [split $cur !] end]
}
proc ::mkitsql::db::setCell {path idx prop value} {
    mk::set $path!$idx $prop $value
    touchPath $path
}
# highest index first, so the rest stay valid
proc ::mkitsql::db::deleteRows {path indices} {
    foreach i [lsort -integer -decreasing -unique $indices] { mk::row delete $path!$i }
    touchPath $path
}

# ---- changing structure ---------------------------------------------------------------------
proc ::mkitsql::db::createView {tag name layout} {
    if {[hasView $tag $name]} { error "View '$name' already exists in '$tag'." }
    mk::view layout $tag.$name [formatLayout $layout]
    touch $tag
}
# `mk::view delete` leaves the ROWS behind: a view created again under the same name would get its old
# rows back.  So the rows are removed first - and if that does not work, the drop is abandoned with the
# original error (nothing is caught): a table is never dropped while its old rows could resurface.
proc ::mkitsql::db::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    mk::view size $tag.$name 0
    set left [mk::view size $tag.$name]
    if {$left != 0} { error "Cannot drop '$name': $left rows could not be cleared." }
    mk::view delete $tag.$name
    touch $tag
}
# Apply a new layout.  Metakit keeps data for properties whose name AND type are unchanged.
proc ::mkitsql::db::restructure {path layout} {
    mk::view layout $path [formatLayout $layout]
    touchPath $path
}
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
    set tmp __mks_tmp
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
