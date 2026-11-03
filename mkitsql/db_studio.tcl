# db_studio.tcl -- the same storage interface as db.tcl, forwarded to MK Studio's ::store package.
#
# Loaded instead of db.tcl when MK Studio's store.tcl is present, so mkit-sql and MK Studio share one
# set of open files.  mkit-sql never reaches into ::store any other way.  Two Metakit behaviours that
# not every version of store.tcl covers are handled here:
#
#   * `mk::view delete` leaves the rows behind, so a table re-created under the same name came back WITH
#     ITS OLD ROWS.  dropView empties the view first - and abandons the drop if that fails (no catch).
#   * older store.tcl versions keep listing a dropped view until the next commit.

namespace eval ::mkitsql::db {}

proc ::mkitsql::db::available {} { ::store::available }
proc ::mkitsql::db::tags {} { ::store::tags }
proc ::mkitsql::db::path {tag} { ::store::path $tag }
proc ::mkitsql::db::readonly {tag} { ::store::readonly $tag }
proc ::mkitsql::db::dirty {tag} { ::store::dirty $tag }
proc ::mkitsql::db::touch {tag} { ::store::touch $tag }
proc ::mkitsql::db::openFile {path args} {
    set unchecked [expr {"-unchecked" in $args}] ; set verify [expr {"-verify" in $args}]
    set fargs {}
    foreach a $args { if {$a ni {-unchecked -verify}} { lappend fargs $a } }
    if {!$unchecked && [file exists [file normalize $path]]} { ::mkitsql::dbRequireIntact [file normalize $path] }
    if {$verify && [file exists [file normalize $path]] && [file size [file normalize $path]] > 0} { ::mkitsql::dbVerify [file normalize $path] }
    set tag [::store::openFile $path {*}$fargs]
    # Mk4tcl opens a damaged file as an empty database; the frame check above catches most damage before the open, this one
    # catches a file that opened with fewer views than its header promises
    set real [file normalize $path]
    if {!$unchecked && [file exists $real] && ![::mkitsql::dbSignatureOk $real [llength [mk::file views $tag]]]} {
        catch {::store::closeFile $tag}
        return -code error -errorcode [list MKIT DAMAGED "not a Metakit database"] "This file isn't a Metakit database, so it was not opened:\n$real"
    }
    return $tag
}
proc ::mkitsql::db::closeFile {tag} { ::store::closeFile $tag ; ::mkitsql::typeForget $tag }
proc ::mkitsql::db::commit {tag} { ::store::commit $tag }
proc ::mkitsql::db::rollback {tag} { ::store::rollback $tag }
proc ::mkitsql::db::layout {path} { ::store::layout $path }
proc ::mkitsql::db::size {path} { ::store::size $path }
proc ::mkitsql::db::subSize {path idx prop} { ::store::subSize $path $idx $prop }
proc ::mkitsql::db::appendRow {path props values} { ::store::appendRow $path $props $values }
proc ::mkitsql::db::setCell {path idx prop value} { ::store::setCell $path $idx $prop $value }
proc ::mkitsql::db::deleteRows {path indices} { ::store::deleteRows $path $indices }
proc ::mkitsql::db::restructure {path layout} {
    if {[string first ! $path] < 0} { lassign [split $path .] tag view ; typeGuard $tag $view $layout }
    ::store::restructure $path $layout
    if {[string first ! $path] < 0} { ::mkitsql::typeRecord $tag $view $layout }
}
proc ::mkitsql::db::parseLayout {spec} { ::store::parseLayout $spec }
proc ::mkitsql::db::formatLayout {layout} { ::store::formatLayout $layout }

# Row indices (ascending) that satisfy ALL of `conds`, decided inside Metakit (in C, ~40x faster than looking at
# every row from Tcl).  conds = list of {exact|min|max column value}; min/max are inclusive.  The caller must pass
# values valid for the column's type.
proc ::mkitsql::db::select {path conds} {
    set args {}
    foreach c $conds { lassign $c op p v ; lappend args -$op $p $v }
    return [mk::select $path {*}$args]
}
proc ::mkitsql::db::deleteRange {path first count} {
    mk::row delete $path!$first $count
    ::store::touchPath $path
}
proc ::mkitsql::db::clearView {path} {
    mk::view size $path 0
    ::store::touchPath $path
}

# who holds the write lock (MK Studio's own advisory lock), for a file this handle opened read-only
proc ::mkitsql::db::lockedBy {tag} {
    if {[llength [info commands ::store::lockedByOther]]} { return [::store::lockedByOther $tag] }
    return ""
}
proc ::mkitsql::db::holdsLock {tag} { expr {![::store::readonly $tag]} }

proc ::mkitsql::db::views {tag} {
    if {[llength [info commands ::store::hasLayout]]} { return [::store::views $tag] }
    set out {}
    foreach v [mk::file views $tag] {
        if {![catch {mk::view layout $tag.$v}]} { lappend out $v }
    }
    return [lsort -dictionary $out]
}
proc ::mkitsql::db::hasView {tag name} { expr {[lsearch -exact [views $tag] $name] >= 0} }

proc ::mkitsql::db::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    if {![catch {::store::parseLayout [mk::view layout $tag.$name]} old]} { ::mkitsql::typeRecord $tag $name $old }
    mk::view size $tag.$name 0
    set left [mk::view size $tag.$name]
    if {$left != 0} { error "Cannot drop '$name': $left rows could not be cleared." }
    mk::view delete $tag.$name
    ::store::touch $tag
}

# (not ::store::createView: older store.tcl versions check for an existing view with their own hasView,
# which still lists a dropped view until the next commit)
proc ::mkitsql::db::typeGuard {tag view newLayout} {
    if {![catch {::store::parseLayout [mk::view layout $tag.$view]} old]} { ::mkitsql::typeRecord $tag $view $old }
    set c [::mkitsql::typeConflict $tag $view $newLayout]
    if {$c ne ""} { ::mkitsql::typeConflictError $view $c }
}
proc ::mkitsql::db::createView {tag name layout} {
    if {[hasView $tag $name]} { error "View '$name' already exists in '$tag'." }
    typeGuard $tag $name $layout
    mk::view layout $tag.$name [::store::formatLayout $layout]
    ::mkitsql::typeRecord $tag $name $layout
    ::store::touch $tag
}
