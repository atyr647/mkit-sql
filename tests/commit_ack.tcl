# An ACKNOWLEDGED commit must survive a power cut that loses the deletion of the commit record.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/commit_ack.tcl
#
# Why: the commit record (<file>.commit) says "if you find me, undo the commit that follows".  The commit deletes it when it is done.  A
# power cut can leave the file as it was written but bring the record back (an unlink that had not reached the disk).  If the record
# still describes the file BEFORE the commit, the next writer undoes a commit that was reported as done.
#
# This is a model, not a real power cut (none can be pulled from a test).  It tracks what is durable for the record file only:
#   * a flush of the record file itself makes its current text durable;
#   * any flush at all syncs the folder, so a record that is gone at that moment is durably gone.
# When the commit returns, the disk is put into the state the model says is durable (the record comes back if its deletion was never
# flushed), the handle is dropped, and the file is opened for writing again, which repairs an interrupted commit.
# Whether the commit is covered then depends on whether anything flushed the folder AFTER the record was deleted:
#   * the new checksum does (sumWrite flushes its own file and the folder) - but only for files it covers (sumLimit, zlib);
#   * so with the checksum switched off (a file over sumLimit, `sumLimit 0`, a runtime without zlib) nothing does.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/mkutil.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 200]\n  want: [string range $want 0 200]"} }
set mkitsql::db::durable 1
set area [tmp mkitsql_ack_[pid]] ; file delete -force $area ; file mkdir $area
set f $area/a.mk ; set rec $f.commit

# what is durable for the record: {exists text}
set ::dur {0 {}}
rename ::mkitsql::db::syncDisk ::mkitsql::db::syncDiskReal
proc ::mkitsql::db::syncDisk {args} {
    set r [syncDiskReal {*}$args]
    set rec $::rec
    if {![file exists $rec]} {
        set ::dur [list 0 {}]
    } elseif {[lsearch -exact $args $rec] >= 0} {
        set h [open $rec rb] ; set t [read $h] ; close $h
        set ::dur [list 1 $t]
    }
    return $r
}
proc powerCut {} {
    lassign $::dur exists text
    if {$exists} { set h [open $::rec wb] ; puts -nonewline $h $text ; close $h } else { file delete $::rec }
}
proc clean {} { foreach x [glob -nocomplain $::f $::f.*] { file delete -force $x } }
proc rowsAfterReopen {} {
    set t [mkitsql::db::openFile $::f]
    set n [mkitsql::db::size $t.t]
    set note [mkitsql::db::repairedNote $t]
    mkitsql::db::closeFile $t
    return [list $n $note]
}

foreach {label sumLimit} {{checksum on (the default)} 512 {checksum off (file over sumLimit, or no zlib)} 0} {
    set mkitsql::db::sumLimit $sumLimit
    clean
    set db [mkitsql::db::openFile $f -create]
    mkitsql::db::createView $db t {{k I {}}}
    for {set i 0} {$i < 50} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    check "$label: the first commit left no record" [file exists $rec] 0
    # an update commit that returns normally = acknowledged
    for {set i 50} {$i < 75} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    check "$label: the acknowledged commit left no record" [file exists $rec] 0
    mkitsql::db::closeFile $db
    powerCut
    lassign [rowsAfterReopen] n note
    check "$label: after the power cut the acknowledged commit is still there (rows)" $n 75
    check "$label: ... and nothing was undone ($note)" [string match "*undone*" $note] 0
}

# the first commit of a new database is protected by repairFile itself (a finished frame beats an 'empty 0' record)
foreach {label sumLimit} {{first commit, checksum on} 512 {first commit, checksum off} 0} {
    set mkitsql::db::sumLimit $sumLimit
    clean
    set db [mkitsql::db::openFile $f -create]
    mkitsql::db::createView $db t {{k I {}}}
    for {set i 0} {$i < 50} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    mkitsql::db::closeFile $db
    powerCut
    lassign [rowsAfterReopen] n note
    check "$label: the database is kept after the power cut" $n 50
}
file delete -force $area
puts "acknowledged commit: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
