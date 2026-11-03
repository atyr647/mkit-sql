# storefix.tcl -- works around Metakit behaviour that MK Studio's store.tcl does not cover.
#
# 1. `mk::view delete` leaves the ROWS behind.  If a view with the same name is created
#    again (DROP TABLE t; CREATE TABLE t ...) the OLD ROWS COME BACK.  Emptying the view
#    first makes the drop real.  (store.tcl in current MK Studio does not do this yet.)
#
# 2. Older versions of store.tcl list a dropped view until the next commit, so
#    DROP TABLE t; CREATE TABLE t (...) failed with "already exists".  Current store.tcl
#    handles that (it has ::store::hasLayout); the versions below are only defined for
#    an older store.tcl.
#
# Once store.tcl itself empties views in dropView this file is harmless.

if {![llength [info commands ::store::hasLayout]]} {
    proc ::store::views {tag} {
        set out {}
        foreach v [mk::file views $tag] {
            if {![catch {mk::view layout $tag.$v}]} { lappend out $v }
        }
        return [lsort -dictionary $out]
    }
    proc ::store::hasView {tag name} {
        expr {[lsearch -exact [::store::views $tag] $name] >= 0}
    }
}

proc ::store::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    catch {mk::view size $tag.$name 0}
    mk::view delete $tag.$name
    touch $tag
}
