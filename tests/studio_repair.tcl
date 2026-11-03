# An interrupted commit is put right when a file is opened for writing THROUGH THE ADAPTER to MK Studio's ::store (db_studio.tcl),
# and the frame check does not refuse the file before that can happen.   MKIT_BACKEND=studio tclkit tests/studio_repair.tcl
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) studio
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 200]\n  want: [string range $want 0 200]"} }
if {$::mkitsql::backend eq "standalone"} { puts "skipped: the studio backend is not loaded" ; exit 0 }
if {![llength [info commands ::store::repairFile]]} { puts "skipped: this MK Studio has no commit repair" ; exit 0 }
set area [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_studiorepair_[pid]
file delete -force $area ; file mkdir $area ; set f $area/r.mk
proc slurp {p} { set h [open $p rb] ; set d [read $h] ; close $h ; return $d }
proc spit {p d} { set h [open $p wb] ; puts -nonewline $h $d ; close $h }
set db [mkitsql::db::openFile $f -create]
mkitsql::run "CREATE TABLE t (id INT, s TEXT)" $db ; mkitsql::run "INSERT INTO t VALUES (1, 'one'), (2, 'two')" $db ; mkitsql::run COMMIT $db
mkitsql::db::closeFile $db
set A [slurp $f]
# 1. an unfinished append (longer than the header says), no record
spit $f "${A}JUNKJUNKJUNK"
check "read-only is refused (it would look empty)" [expr {[catch {mkitsql::db::openFile $f -readonly} m opts] ? [lrange [dict get $opts -errorcode] 0 1] : "opened"}] {MKIT DAMAGED}
set db [mkitsql::db::openFile $f]
check "opened for writing: the tail is cut back" [slurp $f] $A
check "the data is intact" [dict get [mkitsql::run "SELECT id, s FROM t ORDER BY id" $db] rows] {{1 one} {2 two}}
check "the application can be told" [expr {[mkitsql::db::repairedNote $db] ne ""}] 1
mkitsql::db::closeFile $db
# 2. a commit record plus a header that points somewhere else and a longer file: put back as it was
binary scan [string range $A 0 7] H* hex
set rec "$hex [string length $A]"
set bad [string range $A 0 3][binary format I [expr {[string length $A] + 100}]][string range $A 8 end][string repeat Z 100]
spit $f $bad ; spit $f.commit $rec
set db [mkitsql::db::openFile $f]
check "record: the file is exactly what it was before the commit" [slurp $f] $A
check "record: removed" [file exists $f.commit] 0
check "record: the data is intact" [dict get [mkitsql::run "SELECT COUNT(*) FROM t" $db] rows] 2
mkitsql::db::closeFile $db
# 3. a damaged header must never make the repair throw data away
set wrong [string range $A 0 3][binary format I 7][string range $A 8 end]
spit $f $wrong
set rc [catch {mkitsql::db::openFile $f} m opts]
check "a header with a wrong size: refused, file untouched" [list $rc [slurp $f]] [list 1 $wrong]
file delete -force $area
puts "studio repair: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
