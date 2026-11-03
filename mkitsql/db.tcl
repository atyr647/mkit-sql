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
    variable lockOwned       ;# tag -> {lockfile content} of the lock this process holds
    variable lockedBy        ;# tag -> "pid host" of a live writer, for files opened read-only
    variable requireLock 0   ;# 1 = opening for writing fails when no lock file can be created (read-only folder)
    array set lockOwned {} ; array set lockedBy {}
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

# ---- advisory write lock ----------------------------------------------------------------------
# Metakit does no locking: a process reading a file while another commits can see a half-written
# state, and two writers overwrite each other.  Exactly as MK Studio does, a file opened for writing
# gets "<file>.lock" holding "pid host start" (MK Studio reads the first two fields), created
# exclusively; a lock whose process is gone is stale and is taken over; programs that do not know
# the protocol ignore it.  Files opened -readonly take no lock (they just note who holds one).
#
# Beyond MK Studio's version: taking over a stale lock is serialised through "<file>.lock.takeover" so
# two processes finding the same stale lock cannot both win, a recycled pid is recognised by the process
# start time (Linux), and closing never deletes a lock that is no longer ours.
proc ::mkitsql::db::lockPath {path} { return $path.lock }
proc ::mkitsql::db::thisHost {} { if {[catch {info hostname} h]} { return unknown } ; return $h }
# a token that changes when a pid is reused (field 22 of /proc/<pid>/stat), "" where unavailable
proc ::mkitsql::db::procStart {pid} {
    if {[catch {set h [open /proc/$pid/stat r] ; set d [read $h] ; close $h}]} { return "" }
    set rest [string range $d [expr {[string last ")" $d] + 2}] end]
    return [lindex $rest 19]
}
proc ::mkitsql::db::lockContent {} { return "[pid] [thisHost] [procStart [pid]]" }
# "pid host" of a live foreign holder, or "" when the file is unlocked or the lock is stale / ours
proc ::mkitsql::db::lockHolder {path} {
    set lf [lockPath $path]
    if {[catch {set h [open $lf r] ; set d [string trim [read $h]] ; close $h}]} { return "" }
    lassign [split $d " "] pid host start
    if {![string is integer -strict $pid] || $host eq ""} {
        # unreadable: perhaps its owner is between creating and writing it; stale only once it is old
        if {[catch {file mtime $lf} mt] || [clock seconds] - $mt > 10} { return "" }
        return "0 unknown"
    }
    if {$pid == [pid] && $host eq [thisHost]} { return "" }
    if {$host eq [thisHost]} {
        if {![::mkitsql::pidAlive $pid]} { return "" }
        if {$start ne "" && [procStart $pid] ne "" && [procStart $pid] ne $start} { return "" }      ;# pid was reused
        return "$pid $host"
    }
    return "$pid $host"           ;# another machine (network share): cannot tell, so respect it
}
proc ::mkitsql::db::lockedError {holder path} {
    lassign $holder hpid hhost
    return -code error -errorcode [list MKIT LOCKED $hpid $hhost] \
        "This database is open for editing in another process (pid $hpid on $hhost):\n$path"
}
# Returns the lock content that was written, "" when no lock could be made (read-only folder) or raises
# MKIT LOCKED when a live process holds it.
proc ::mkitsql::db::takeLock {path} {
    set lf [lockPath $path] ; set mine [lockContent]
    for {set attempt 0} {$attempt < 5} {incr attempt} {
        if {![catch {open $lf {WRONLY CREAT EXCL} 0644} h]} { puts -nonewline $h $mine ; close $h ; return $mine }
        if {![file exists $lf]} { return "" }                                        ;# could not create it for another reason
        set holder [lockHolder $path]
        if {$holder ne ""} { return [lockedError $holder $path] }
        # stale: remove it under a short-lived mutex, re-checking inside, so a competitor that is doing the
        # same thing cannot delete the lock we (or it) just created
        set mx $lf.takeover
        if {![catch {open $mx {WRONLY CREAT EXCL} 0644} mh]} {
            close $mh
            if {[lockHolder $path] eq ""} {
                catch {file delete $lf}
                set rc [catch {open $lf {WRONLY CREAT EXCL} 0644} h]
                catch {file delete $mx}
                if {!$rc} { puts -nonewline $h $mine ; close $h ; return $mine }
            } else { catch {file delete $mx} }
        } elseif {![catch {file mtime $mx} mt] && [clock seconds] - $mt > 30} {
            catch {file delete $mx}                                                   ;# a crashed takeover
        }
    }
    return -code error -errorcode [list MKIT LOCKED 0 unknown] "Could not take the lock on this database (another process is starting at the same moment), please repeat:\n$path"
}
# Release our lock - only if the file still holds OUR content.
proc ::mkitsql::db::releaseLock {path mine} {
    set lf [lockPath $path]
    if {![catch {set h [open $lf r] ; set d [read $h] ; close $h}] && $d eq $mine} { catch {file delete $lf} }
}
# Who blocks writing to this file?  "pid host" of the live writer a read-only handle noticed, else "".
proc ::mkitsql::db::lockedBy {tag} { variable lockedBy ; if {[info exists lockedBy($tag)]} { return $lockedBy($tag) } ; return "" }
# Does this handle hold the write lock?  (0 when it is read-only or the folder did not allow a lock file)
proc ::mkitsql::db::holdsLock {tag} { variable lockOwned ; return [info exists lockOwned($tag)] }

# Open (or with -create, create) a datafile; returns its tag.  Options: -create -readonly
proc ::mkitsql::db::openFile {path args} {
    variable tags ; variable file ; variable ro ; variable dirty ; variable lockOwned ; variable lockedBy ; variable requireLock
    set create 0 ; set readonly 0 ; set unchecked 0
    foreach a $args {
        switch -- $a { -create {set create 1} -readonly {set readonly 1} -unchecked {set unchecked 1} default { error "unknown option $a" } }
    }
    set path [::file normalize $path]
    foreach t $tags { if {$file($t) eq $path} { error "File is already open as '$t'." } }
    if {!$create && ![::file exists $path]} { error "File not found: $path" }
    if {!$unchecked} { ::mkitsql::dbRequireIntact $path }       ;# a damaged file would open as an empty database
    set mine ""
    if {!$readonly} {
        set mine [takeLock $path]                       ;# before opening, so a refusal touches nothing
        if {$mine eq "" && $requireLock} { error "Cannot create the lock file for $path (is the folder writable?)" }
    }
    set tag [makeTag $path]
    set opts {-nocommit}
    if {$readonly} { lappend opts -readonly }
    if {[catch {mk::file open $tag $path {*}$opts}]} {
        # a very old Mk4tcl without -nocommit
        if {[catch {mk::file open $tag $path {*}[expr {$readonly ? {-readonly} : {}}]} err]} {
            if {$mine ne ""} { releaseLock $path $mine }
            error $err
        }
    }
    if {!$unchecked && !$create && ![::mkitsql::dbSignatureOk $path [llength [mk::file views $tag]]]} {
        catch {mk::file close $tag}
        if {$mine ne ""} { releaseLock $path $mine }
        return -code error -errorcode [list MKIT DAMAGED "not a Metakit database"] "This file isn't a Metakit database, so it was not opened:\n$path"
    }
    lappend tags $tag
    set file($tag) $path ; set ro($tag) $readonly ; set dirty($tag) 0
    if {$readonly} {
        set h [lockHolder $path]
        if {$h ne ""} { set lockedBy($tag) $h }
    } elseif {$mine ne ""} {
        set lockOwned($tag) $mine
    }
    return $tag
}
proc ::mkitsql::db::closeFile {tag} {
    variable tags ; variable file ; variable ro ; variable dirty ; variable lockOwned ; variable lockedBy
    if {[info exists lockOwned($tag)]} { releaseLock $file($tag) $lockOwned($tag) ; unset lockOwned($tag) }
    unset -nocomplain lockedBy($tag)
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

# Row indices (ascending) that satisfy ALL of `conds`, decided inside Metakit (in C, ~40x faster than looking at
# every row from Tcl).  conds = list of {exact|min|max column value}; min/max are inclusive.  The caller must pass
# values valid for the column's type.
proc ::mkitsql::db::select {path conds} {
    set args {}
    foreach c $conds { lassign $c op p v ; lappend args -$op $p $v }
    return [mk::select $path {*}$args]
}
# the given rows (indices) in the order of `props`, like `rows`
proc ::mkitsql::db::rowsAt {path props indices} {
    set out {}
    set np [llength $props]
    if {$np == 0} { foreach i $indices { lappend out {} } ; return $out }
    if {$np == 1} {
        set p [lindex $props 0]
        foreach i $indices { lappend out [list [mk::get $path!$i $p]] }
        return $out
    }
    foreach i $indices { lappend out [mk::get $path!$i {*}$props] }
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

# `count` consecutive rows from `first` in one call (cheaper than one call per row)
proc ::mkitsql::db::deleteRange {path first count} {
    mk::row delete $path!$first $count
    touchPath $path
}
# remove every row of a view (and of its subviews), keeping the layout
proc ::mkitsql::db::clearView {path} {
    mk::view size $path 0
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
