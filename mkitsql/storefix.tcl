# storefix.tcl -- works around a real-Metakit quirk in MK Studio's store.tcl.
#
# After `mk::view delete`, real Mk4tcl keeps listing the dropped view in
# `mk::file views` until the file is committed, although its layout can no longer
# be read.  store::views / store::hasView therefore report phantom tables, which
# makes  DROP TABLE t; CREATE TABLE t (...)  fail with "already exists" and breaks
# the Object Explorer's view list.  The versions below skip views whose layout
# cannot be read.  (The proper fix is the same two procs in store.tcl; once it is
# there this file is harmless.)

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

# `mk::view delete` leaves the rows behind: if a view with the same name is created
# again (DROP TABLE t; CREATE TABLE t ...), the OLD ROWS COME BACK.  Emptying the
# view first makes the drop real.  (The caught error is for the Mk4tcl stand-in.)
proc ::store::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    catch {mk::view size $tag.$name 0}
    mk::view delete $tag.$name
    touch $tag
}
