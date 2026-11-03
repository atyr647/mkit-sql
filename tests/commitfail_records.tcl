set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" } }
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
proc fresh {name} { global tmp ; set f $tmp/mkitsql_rec_[pid]_$name.mk ; foreach x [list $f $f.commit $f.lock] { file delete -force $x } ; return $f }
proc mkdb {f n} {
    set db [mkitsql::db::openFile $f -create]
    mkitsql::db::createView $db t {{k I {}}}
    for {set i 0} {$i < $n} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    return $db
}
# 1. a finished first commit whose record was left behind ("empty 0") must not empty the database
set f [fresh a] ; set db [mkdb $f 50] ; mkitsql::db::closeFile $db
set h [open $f.commit w] ; puts -nonewline $h "empty 0" ; close $h
set db [mkitsql::db::openFile $f]
check "stale 'empty 0' record: data kept" [mkitsql::db::size $db.t] 50
check "... and the record is gone" [file exists $f.commit] 0
mkitsql::db::closeFile $db
# 2. an empty record (what a record that could not be deleted is turned into) is harmless
set f [fresh b] ; set db [mkdb $f 20] ; mkitsql::db::closeFile $db
close [open $f.commit w]
set db [mkitsql::db::openFile $f]
check "empty record: data kept" [mkitsql::db::size $db.t] 20
mkitsql::db::closeFile $db
# 3. a record that cannot be written: the commit still happens, and says it was unprotected
set f [fresh c] ; file mkdir $f.commit
set db [mkitsql::db::openFile $f -create]
mkitsql::db::createView $db t {{k I {}}}
mkitsql::db::appendRow $db.t k 1
check "unwritable record: commit goes ahead" [catch {mkitsql::db::commit $db}] 0
check "... and is reported as unprotected" [mkitsql::db::commitUnprotected $db] 1
mkitsql::db::closeFile $db ; file delete -force $f.commit
# 4. a lock path that is not a file: a read-only open fails cleanly and leaves nothing registered
set f [fresh d] ; set db [mkdb $f 5] ; mkitsql::db::closeFile $db
file mkdir $f.lock
set before [llength [mkitsql::db::tags]]
check "read-only open with a directory as lock path fails" [catch {mkitsql::db::openFile $f -readonly}] 1
check "... and registers nothing" [llength [mkitsql::db::tags]] $before
file delete -force $f.lock
set db [mkitsql::db::openFile $f -readonly]
check "... and works once the obstacle is gone" [mkitsql::db::size $db.t] 5
mkitsql::db::closeFile $db
# 5. without the lock nothing is repaired (another writer may be in the middle of a commit): junk after the footer stays, the open is refused
set f [fresh e] ; set db [mkdb $f 30] ; mkitsql::db::closeFile $db
set h [open $f a] ; fconfigure $h -translation binary ; puts -nonewline $h [string repeat Z 500] ; close $h
set size [file size $f]
set mkitsql::db::requireLock 0
file mkdir $f.lock                                  ;# no lock file can be created
set r [catch {mkitsql::db::openFile $f} msg]
check "no lock, unfinished tail: nothing is cut off" [file size $f] $size
file delete -force $f.lock
foreach x [list $f $f.commit $f.lock] { file delete -force $x }
puts "records: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
