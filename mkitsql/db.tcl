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
# Metakit does no locking: a process reading a file while another commits can see a half-written state, and two
# writers overwrite each other.  This is the protocol of MK Studio's docs/CONCURRENCY.md, implemented to the letter so
# that mkit-sql, MK Studio and a server exclude each other (tests/locking.tcl runs the spec's checks against this code,
# and MKSTUDIO_DIR=... runs real MK Studio processes against it):
#   * a file opened for writing owns "<file>.lock", one line "pid host [role [endpoint]]", created with O_EXCL;
#   * a lock is HELD (respected) when its process is alive on this host or when it names another host, STALE when
#     this host's process is gone or the file is empty/garbled and older than 5 s, OURS when it names this process;
#   * stale and ours are taken over under "<file>.lock.guard" (created exclusively; a guard older than 10 s was
#     abandoned by a crash): classify again with the guard held, delete the lock, delete the guard, create again;
#   * closing deletes the lock only if it still names us.  Files opened -readonly take no lock.
# Beyond the letter of the protocol (all of it only makes the checks stricter, never looser):
#   * a lock file that is not a regular file (a link, a folder, a fifo) is refused, never followed or read;
#   * a pid that was recycled (the process is younger than the lock file; Linux) counts as dead;
#   * the path is resolved through symbolic links first, so two names of one file share one lock.
# Limits (see docs/SQL.md): the lock is advisory; a hard link is another name Metakit cannot tell apart; processes
# in different PID namespaces that share a host name and a folder cannot see each other's pids.
namespace eval ::mkitsql::db {
    variable lockRole "" ; variable lockEndpoint ""     ;# a server announces itself: set before openFile
}
proc ::mkitsql::db::lockPath {path} { return $path.lock }
proc ::mkitsql::db::thisHost {} { if {[catch {info hostname} h]} { return unknown } ; return $h }
proc ::mkitsql::db::lockText {} {
    variable lockRole ; variable lockEndpoint
    set t "[pid] [thisHost]"
    if {$lockRole ne "" || $lockEndpoint ne ""} { append t " [expr {$lockRole eq {} ? {-} : $lockRole}]" }
    if {$lockEndpoint ne ""} { append t " $lockEndpoint" }
    return $t
}
# the real location of a file: symbolic links in the last component are followed too (`file normalize` does not)
proc ::mkitsql::db::realPath {p} {
    set p [::file normalize $p]
    for {set n 0} {$n < 40} {incr n} {
        if {[catch {::file readlink $p} t]} break
        set p [::file normalize [::file join [::file dirname $p] $t]]
    }
    return $p
}
# epoch second when a local process started (Linux: /proc/<pid>/stat field 22 and /proc/stat btime), "" where unknown
proc ::mkitsql::db::procStartTime {pid} {
    if {[catch {set h [open /proc/$pid/stat r] ; set d [read $h] ; close $h}]} { return "" }
    set rest [string range $d [expr {[string last ")" $d] + 2}] end]
    set ticks [lindex $rest 19]
    if {![string is integer -strict $ticks]} { return "" }
    if {[catch {set h [open /proc/stat r] ; set st [read $h] ; close $h}] || ![regexp {btime (\d+)} $st -> btime]} { return "" }
    return [expr {$btime + $ticks / 100}]
}
# The lock file as a dict: state free|ours|stale|held, and pid host role endpoint when there is one.
proc ::mkitsql::db::lockInfo {path} {
    set lf [lockPath $path]
    if {[catch {::file lstat $lf st}]} { return [dict create state free] }
    if {$st(type) ne "file"} {
        return -code error -errorcode [list MKIT BADLOCK $lf] "The lock path is not a regular file ($st(type)); refusing to use it:\n$lf"
    }
    # a bounded read of a regular file: a hostile or damaged lock file cannot make us read for ever
    if {[catch {set h [open $lf r] ; set d [string trim [read $h 512]] ; close $h}]} { return [dict create state free] }   ;# vanished meanwhile
    lassign [split $d " "] pid host role endpoint
    set info [dict create pid $pid host $host role [expr {$role eq "-" ? "" : $role}] endpoint $endpoint]
    set state held
    if {![string is integer -strict $pid] || $host eq ""} {
        # empty or garbled: its creator is probably between creating and writing it; stale only once it has stayed so for a while
        variable emptyStale
        if {[clock seconds] - $st(mtime) > $emptyStale} { set state stale }
    } elseif {$pid == [pid] && $host eq [thisHost]} {
        set state ours
    } elseif {$host eq [thisHost]} {
        if {![::mkitsql::pidAlive $pid]} {
            set state stale
        } else {
            set started [procStartTime $pid]
            if {$started ne "" && $started > $st(mtime) + 2} { set state stale }      ;# the pid was recycled: that process started after the lock was made
        }
    }
    return [dict merge $info [dict create state $state]]
}
# "pid host role endpoint" of a live foreign holder, or "" when the file is unlocked / stale / ours
proc ::mkitsql::db::lockHolder {path} {
    set i [lockInfo $path]
    if {[dict get $i state] ne "held"} { return "" }
    return [list [dict get $i pid] [dict get $i host] [dict get $i role] [dict get $i endpoint]]
}
proc ::mkitsql::db::lockedError {holder path} {
    lassign $holder hpid hhost hrole hend
    set who "pid $hpid on $hhost"
    if {$hrole ne ""} { append who ", $hrole" }
    if {$hend ne ""} { append who " at $hend" }
    return -code error -errorcode [list MKIT LOCKED $hpid $hhost $hrole $hend] \
        "This database is open for editing in another process ($who):\n$path"
}
# Create our lock file; returns its text, "" when no lock could be made (read-only folder or disk: carry on unlocked),
# or raises MKIT LOCKED when somebody else owns it.
# Try to create our lock file.  Returns {created text}, {exists} (something is already there - or was a moment ago), or
# {blocked} (the folder will not hold a file: read-only, no permission, disk full - run unlocked).  Only a refusal of the
# folder itself means "blocked": a file that has vanished again by the time we look is a competitor that just released or
# replaced the lock, never "no lock needed" (treating it so let two processes both believe they owned the database).
proc ::mkitsql::db::createLock {lf mine} {
    if {[catch {open $lf {WRONLY CREAT EXCL} 0644} h opts]} {
        set code [dict get $opts -errorcode]
        if {[lindex $code 0] eq "POSIX" && [lindex $code 1] eq "EEXIST"} { return [list exists] }
        return [list blocked]
    }
    lockStep created
    if {[catch {puts -nonewline $h $mine ; close $h} err]} {
        # the write failed (a full disk): an empty lock would keep everybody out until it is old - remove it and go on unlocked
        catch {close $h} ; catch {::file delete $lf}
        return [list blocked]
    }
    lockStep written
    # tidy up a takeover guard abandoned by a crashed process (it is harmless but would otherwise stay for ever)
    variable mutexStale
    if {![catch {::file mtime $lf.guard} mt] && [clock seconds] - $mt > $mutexStale} { catch {::file delete $lf.guard} }
    return [list created $mine]
}
# test hook: a script prefix called with the name of each step of taking a lock (tests kill the process or race it there)
namespace eval ::mkitsql::db { variable lockHook "" ; variable emptyStale 5 ; variable mutexStale 10 }
proc ::mkitsql::db::lockStep {name} { variable lockHook ; if {$lockHook ne ""} { {*}$lockHook $name } }
proc ::mkitsql::db::takeLock {path} {
    variable mutexStale
    set lf [lockPath $path] ; set mine [lockText]
    for {set attempt 0} {$attempt < 60} {incr attempt} {
        set r [createLock $lf $mine]
        switch -- [lindex $r 0] {
            created { return [lindex $r 1] }
            blocked { return "" }
        }
        lockStep create-failed
        if {[catch {::file lstat $lf st}]} { continue }                       ;# it vanished: a competitor released or replaced it - try again
        set holder [lockHolder $path]
        if {$holder ne ""} { return [lockedError $holder $path] }
        # stale (or ours from an earlier run): replace it, one process at a time, under the guard
        set guard $lf.guard
        if {[catch {set gh [open $guard {WRONLY CREAT EXCL} 0644] ; close $gh}]} {
            # somebody else is replacing the lock: a guard older than mutexStale was abandoned by a crash, otherwise give them a
            # moment (about 2.4 s over all attempts, as the protocol says) and look again
            if {![catch {::file mtime $guard} mt] && [clock seconds] - $mt > $mutexStale} { catch {::file delete $guard} } else { after 40 }
            continue
        }
        lockStep mutex
        set again [lockHolder $path]                                           ;# look again now that nobody else is replacing it
        if {$again eq "" && [dict get [lockInfo $path] state] in {stale ours}} { catch {::file delete $lf} ; lockStep deleted }
        catch {::file delete $guard}
        if {$again ne ""} { return [lockedError $again $path] }
    }
    return -code error -errorcode [list MKIT LOCKED 0 unknown {} {}] "Could not take the lock on this database (another process is starting at the same moment), please repeat:\n$path"
}
# Release our lock - only if the file still holds OUR content (a regular file, read with a bound).
proc ::mkitsql::db::releaseLock {path mine} {
    set lf [lockPath $path]
    if {[catch {::file lstat $lf st}] || $st(type) ne "file"} return
    if {![catch {set h [open $lf r] ; set d [read $h 512] ; close $h}] && $d eq $mine} { catch {::file delete $lf} ; lockStep released }
}
# Who blocks writing to this file?  "pid host role endpoint" of the live writer a read-only handle noticed, else "".
proc ::mkitsql::db::lockedBy {tag} { variable lockedBy ; if {[info exists lockedBy($tag)]} { return $lockedBy($tag) } ; return "" }
# Does this handle hold the write lock?  (0 when it is read-only or the folder did not allow a lock file)
proc ::mkitsql::db::holdsLock {tag} { variable lockOwned ; return [info exists lockOwned($tag)] }

# Open (or with -create, create) a datafile; returns its tag.  Options: -create -readonly
proc ::mkitsql::db::openFile {path args} {
    variable tags ; variable file ; variable ro ; variable dirty ; variable lockOwned ; variable lockedBy ; variable requireLock
    set create 0 ; set readonly 0 ; set unchecked 0 ; set verify 0
    foreach a $args {
        switch -- $a { -create {set create 1} -readonly {set readonly 1} -unchecked {set unchecked 1} -verify {set verify 1} default { error "unknown option $a (use -create, -readonly, -unchecked or -verify)" } }
    }
    set path [realPath $path]
    foreach t $tags { if {$file($t) eq $path} { error "File is already open as '$t': $path" } }
    if {!$create && ![::file exists $path]} { error "File not found: $path" }
    if {!$unchecked} { ::mkitsql::dbRequireIntact $path }       ;# a damaged file would open as an empty database
    if {$verify && [::file exists $path] && [::file size $path] > 0} { ::mkitsql::dbVerify $path }   ;# untrusted: read it all in a throw-away process first
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
            error "Cannot open $path: $err"
        }
    }
    if {!$unchecked && ![::mkitsql::dbSignatureOk $path [llength [mk::file views $tag]]]} {
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
    ::mkitsql::typeForget $tag                       ;# what Metakit remembers about column types dies with the open file
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

# Close and reopen the file (same tag, same lock): resets Metakit's memory of column types.  Only with nothing pending.
proc ::mkitsql::db::reopen {tag} {
    variable file ; variable ro ; variable dirty
    if {$dirty($tag) > 0} { error "cannot reopen '$tag' with uncommitted changes" }
    catch {mk::file close $tag}
    set opts {-nocommit}
    if {$ro($tag)} { lappend opts -readonly }
    mk::file open $tag $file($tag) {*}$opts
    ::mkitsql::typeForget $tag
}
# Before a view gets a layout: remember what it has now, and refuse (or reopen first) if the new layout would change the
# type of a column that has already existed under that name (see dbcheck.tcl).
proc ::mkitsql::db::typeGuard {tag view newLayout} {
    variable dirty
    if {![catch {parseLayout [mk::view layout $tag.$view]} old]} { ::mkitsql::typeRecord $tag $view $old }
    set c [::mkitsql::typeConflict $tag $view $newLayout]
    if {$c eq ""} return
    if {$dirty($tag) == 0} {
        reopen $tag
        if {![catch {parseLayout [mk::view layout $tag.$view]} old]} { ::mkitsql::typeRecord $tag $view $old }
        set c [::mkitsql::typeConflict $tag $view $newLayout]
        if {$c eq ""} return
    }
    ::mkitsql::typeConflictError $view $c
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

# Row indices (ascending) that satisfy ALL of `conds`, decided inside Metakit (in C, ~40x faster than looking at
# every row from Tcl).  conds = list of {exact|min|max column value}; min/max are inclusive.  The caller must pass
# values valid for the column's type.
proc ::mkitsql::db::select {path conds} {
    set args {}
    foreach c $conds { lassign $c op p v ; lappend args -$op $p $v }
    return [mk::select $path {*}$args]
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
    typeGuard $tag $name $layout
    mk::view layout $tag.$name [formatLayout $layout]
    ::mkitsql::typeRecord $tag $name $layout
    touch $tag
}
# `mk::view delete` leaves the ROWS behind: a view created again under the same name would get its old
# rows back.  So the rows are removed first - and if that does not work, the drop is abandoned with the
# original error (nothing is caught): a table is never dropped while its old rows could resurface.
proc ::mkitsql::db::dropView {tag name} {
    if {![hasView $tag $name]} { error "View '$name' does not exist in '$tag'." }
    if {![catch {parseLayout [mk::view layout $tag.$name]} old]} { ::mkitsql::typeRecord $tag $name $old }   ;# its types stay "seen"
    mk::view size $tag.$name 0
    set left [mk::view size $tag.$name]
    if {$left != 0} { error "Cannot drop '$name': $left rows could not be cleared." }
    mk::view delete $tag.$name
    touch $tag
}
# Apply a new layout.  Metakit keeps data for properties whose name AND type are unchanged.
proc ::mkitsql::db::restructure {path layout} {
    if {[string first ! $path] < 0} { lassign [split $path .] tag view ; typeGuard $tag $view $layout }
    mk::view layout $path [formatLayout $layout]
    if {[string first ! $path] < 0} { ::mkitsql::typeRecord $tag $view $layout }
    touchPath $path
}
