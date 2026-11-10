# What is durable for the commit record, for the power-cut tests (commit_ack.tcl, commit_crash.tcl).  Not a real power cut - none can be
# pulled from a test - but a model of the two facts that matter here:
#   * a flush of the record file itself makes its current text durable;
#   * any flush at all syncs the folder, so a record that is gone at that moment is durably gone.
# Source this after the engine is loaded, set ::modelRec to the record's path, and call powerCut where the power fails: the record on
# disk becomes what the model says was durable (it comes back if its deletion was never flushed).
set ::modelDur {0 {}}
set ::modelRec ""
rename ::mkitsql::db::syncDisk ::mkitsql::db::syncDiskReal
proc ::mkitsql::db::syncDisk {args} {
    set r [syncDiskReal {*}$args]
    set rec $::modelRec
    if {![file exists $rec]} {
        set ::modelDur [list 0 {}]
    } elseif {[lsearch -exact $args $rec] >= 0} {
        set h [open $rec rb] ; set t [read $h] ; close $h
        set ::modelDur [list 1 $t]
    }
    return $r
}
proc powerCut {} {
    lassign $::modelDur exists text
    if {$exists} { set h [open $::modelRec wb] ; puts -nonewline $h $text ; close $h } else { file delete $::modelRec }
}
