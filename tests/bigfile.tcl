# The 2 GiB ceiling of a Metakit file, on REAL Metakit.   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/bigfile.tcl
# Needs about 2.5 GB of free disk and half a minute.  Metakit keeps a file's size in one 32-bit word; measured: a commit that would
# take the file past 2 GiB fails ("I/O error during commit") and, if it was a big one, leaves a file that crashes Metakit on open.
# mkit-sql must give the file back as it was at the last commit and keep working.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc ok {name cond {info ""}} { global pass fail ; if {$cond} { incr pass } else { incr fail ; puts "FAIL $name $info" } }
set dir [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $dir/mkitsql_bigfile_[pid].mk ; file delete $f
if {[mkitsql::db::available] eq "0"} { puts "no Metakit" ; exit 2 }
set db [mkitsql::db::openFile $f -create]
mkitsql::db::createView $db t {{k I {}} {b B {}}}
set blob [string repeat x 1048576]
set mkitsql::db::durable 0                       ;# the fill phase need not force 2 GB to disk 40 times
set n 0
while {$n < 2000} { for {set j 0} {$j < 50} {incr j} { mkitsql::db::appendRow $db.t {k b} [list $n $blob] ; incr n } ; mkitsql::db::commit $db }
set mkitsql::db::durable 1
set before [file size $f] ; set hdr0 [mkitsql::db::headerInfo $f]
puts "file at 2000 MB: $before bytes"
ok "headroom is the ceiling minus the size" [expr {[mkitsql::db::fileHeadroom $db] == 2147483647 - $before}]
ok "near the limit at 90 %" [mkitsql::db::nearLimit $db 0.9]
ok "not near at 99.9 %" [expr {![mkitsql::db::nearLimit $db 0.999]}]
# a big commit that crosses the limit
for {set j 0} {$j < 100} {incr j} { mkitsql::db::appendRow $db.t {k b} [list [expr {$n + $j}] $blob] }
set rc [catch {mkitsql::db::commit $db} err opts]
ok "crossing commit is refused" $rc
ok "error code" [expr {[lrange [dict get $opts -errorcode] 0 1] eq {MKIT COMMITFAILED}}] [dict get $opts -errorcode]
ok "message names the limit" [string match "*2 GiB*" $err] $err
ok "file is as it was (size)" [expr {[file size $f] == $before}] "[file size $f] vs $before"
ok "file is as it was (header)" [expr {[mkitsql::db::headerInfo $f] eq $hdr0}]
ok "no commit record left" [expr {![file exists [mkitsql::db::commitRecord $f]]}]
ok "the handle works: 2000 rows" [expr {[mkitsql::db::size $db.t] == 2000}] [mkitsql::db::size $db.t]
mkitsql::db::appendRow $db.t {k b} [list 9999 "small"]
mkitsql::db::commit $db
ok "a small commit still works" [expr {[mkitsql::db::size $db.t] == 2001}]
mkitsql::db::closeFile $db
# a fresh process can open it
set out [lindex [split [string trim [exec [info nameofexecutable] $here/bigfile_child.tcl $f]] "\n"] end]
ok "reopened in a new process" [string match "2001 *" $out] $out
file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "bigfile: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
