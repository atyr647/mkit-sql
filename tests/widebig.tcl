# A database file past 2 GiB, on the Metakit with 64-bit file positions (https://github.com/atyr647/metakit).  Needs about 4.5 GB of free
# disk and a few minutes; skipped (exit 0) with a Mk4tcl that cannot hold such a file.
#   MKIT_MK4TCL=/path/Mk4tcl.so tclsh tests/widebig.tcl
# What it shows: commits cross 2 GiB, the file stays readable and writable, every value is still the one written, the engine says the
# headroom is huge, one COLUMN still cannot pass 2 GiB and is refused cleanly (Metakit would end the program), a process killed in the middle
# of a commit leaves a file that opens as one commit or the other, and the helper that reads the whole file in -verify copes.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc ok {name cond {info ""}} { global pass fail ; if {$cond} { incr pass } else { incr fail ; puts "FAIL $name $info" } }
if {[mkitsql::db::available] eq "0" || $::mk4kind eq "stand-in"} { puts "widebig: needs a real Mk4tcl; skipped" ; exit 0 }
if {![mkitsql::db::wideCapable]} { puts "widebig: this Mk4tcl cannot hold files over 2 GiB; skipped" ; exit 0 }
set dir [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $dir/mkitsql_widebig_[pid].mk ; file delete $f
set GiB 1073741824
set db [mkitsql::db::openFile $f -create]
mkitsql::db::createView $db t {{k I {}} {b1 B {}} {b2 B {}} {b3 B {}}}
set pad [string repeat x 1048568]
set mkitsql::db::durable 0                       ;# the fill phase need not force gigabytes to disk 30 times
set n 0
while {$n < 1500} {
    for {set j 0} {$j < 50} {incr j} { mkitsql::db::appendRow $db.t {k b1 b2} [list $n [format %08d $n]$pad [format %08d $n]$pad] ; incr n }
    mkitsql::db::commit $db
}
set mkitsql::db::durable 1
set size [file size $f]
puts "file: $size bytes ([expr {$size / double($GiB)}] GiB)"
ok "the file is over 2 GiB" [expr {$size > 2 * $GiB}]
ok "it uses the wide format" [mkitsql::db::isWide $f]
ok "its frame is valid" [expr {[mkitsql::dbProblem $f] eq ""}] [mkitsql::dbProblem $f]
ok "headroom is far beyond 2 GiB" [expr {[mkitsql::db::fileHeadroom $db] > 1024 * $GiB}]
ok "not near the limit" [expr {![mkitsql::db::nearLimit $db 0.9]}]
ok "all rows are there" [expr {[mkitsql::db::size $db.t] == 1500}]
# every value is the one written (the value of a row is read back by its own number)
set bad 0
for {set i 0} {$i < 1500} {incr i} {
    set v [mk::get $db.t!$i b1]
    if {[string range $v 0 7] ne [format %08d $i] || [string length $v] != 1048576} { incr bad }
    set v [mk::get $db.t!$i b2]
    if {[string range $v 0 7] ne [format %08d $i] || [string length $v] != 1048576} { incr bad }
}
ok "every blob is intact" [expr {$bad == 0}] $bad
set r [mkitsql::run {UPDATE t SET k = k + 100000 WHERE k = 1499} $db]
mkitsql::db::commit $db
ok "an UPDATE past 2 GiB commits" [expr {[dict get [mkitsql::run {SELECT COUNT(*) AS c FROM t WHERE k = 101499} $db] rows] eq {1}}]
mkitsql::db::closeFile $db
set out [lindex [split [string trim [exec [info nameofexecutable] $here/bigfile_child.tcl $f 2>@1]] "\n"] end]
ok "a new process opens it and counts" [string match "1500 rows 1500" $out] $out
# a program that cannot read wide files refuses it
set out [lindex [split [string trim [exec [info nameofexecutable] $here/widefile_child.tcl $f 2>@1]] "\n"] end]
ok "MKIT_WIDE=0 refuses the file" [string match "refused MKIT WIDEFILE" $out] $out
# -verify reads the whole file in a helper
set ::mkitsql::verifyTimeout 900
set t0 [clock seconds]
set db [mkitsql::db::openFile $f -readonly -verify]
puts "-verify of [format %.2f [expr {$size / double($GiB)}]] GiB: [expr {[clock seconds] - $t0}] s, [mkitsql::db::integrityOf $db]"
ok "-verify gives a level" [expr {[lindex [mkitsql::db::integrityOf $db] 1] in {proven evidence}}]
mkitsql::db::closeFile $db

# ---- one column cannot pass 2 GiB: b1 holds about 1.5 GiB, so about 500 more MiB fit ----
set db [mkitsql::db::openFile $f]
set mkitsql::db::durable 0
set added 0 ; set code ""
for {set i 0} {$i < 900} {incr i} {
    if {[catch {mkitsql::db::appendRow $db.t {k b1} [list [expr {200000 + $i}] [format %08d [expr {200000 + $i}]]$pad]} m opts]} { set code [dict get $opts -errorcode] ; break }
    incr added
    if {$added % 50 == 0} { mkitsql::db::commit $db }
}
ok "the column was refused before Metakit could end the program (COLUMNFULL after $added MiB)" [expr {[lrange $code 0 1] eq {MKIT COLUMNFULL}}] $code
ok "the refusal is near 2 GiB" [expr {$added > 400 && $added < 560}] $added
ok "the other column is fine" [expr {![catch {mkitsql::db::appendRow $db.t {k b2} [list 1 small]}]}]
mkitsql::db::commit $db
set rows [mkitsql::db::size $db.t]
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f -readonly]
ok "after the refusal the file reopens with every row" [expr {[mkitsql::db::size $db.t] == $rows}] "[mkitsql::db::size $db.t] vs $rows"
mkitsql::db::closeFile $db

# ---- a process killed in the middle of a commit (Unix only) ----
if {$::tcl_platform(platform) eq "unix"} {
    set base 500000 ; set undone 0 ; set kept 0
    for {set round 0} {$round < 6} {incr round} {
        set db [mkitsql::db::openFile $f -readonly] ; set before [mkitsql::db::size $db.t] ; mkitsql::db::closeFile $db
        set ch [open [list | [info nameofexecutable] $here/widebig_child.tcl $f 120 $base 2>@1] r]
        set reached 0 ; set said ""
        while {[gets $ch line] >= 0} { if {$line eq "COMMITTING"} { set reached 1 ; break } ; append said $line " " }
        ok "kill round $round: the child got as far as its commit" $reached $said
        set delay [expr {int(rand() * 2500)}] ; after $delay
        catch {exec kill -9 [pid $ch]} ; catch {close $ch}
        incr base 1000
        set d [mkitsql::db::openFile $f]                       ;# for writing: puts right an interrupted commit
        set after [mkitsql::db::size $d.t]
        if {$after == $before} { incr undone } else { incr kept }
        set note [mkitsql::db::repairedNote $d]
        puts "kill round $round: killed [format %4d $delay] ms after the commit began: $before -> $after rows[expr {$note ne "" ? ", $note" : ""}]"
        ok "kill round $round: the file holds one commit or the other ($before -> $after)" [expr {$after == $before || $after == $before + 120}]
        ok "kill round $round: the frame is valid" [expr {[mkitsql::dbProblem $f] eq ""}] [mkitsql::dbProblem $f]
        mkitsql::db::appendRow $d.t {k b2} [list $round after]
        mkitsql::db::commit $d
        ok "kill round $round: later commits work" [expr {[mkitsql::db::size $d.t] == $after + 1}]
        mkitsql::db::closeFile $d
    }
}
if {[info exists undone]} { puts "killed commits: $undone left the file at the previous commit, $kept had finished" }
file delete $f ; file delete [mkitsql::db::commitRecord $f] ; file delete $f.sum $f.lock
puts "widebig: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
