# Files over 2 GiB and the Metakit that can hold them (https://github.com/atyr647/metakit, the 64-bit file positions).
# Works with ANY Mk4tcl and with small files: a "wide" file is made from an ordinary one the way that Metakit writes it past 2 GiB
# (three 24-byte tails, header flag 0x40; ::mkitsql::db::wideConvert), so
#   * with a stock Mk4tcl the engine must refuse such a file (it would look empty) and change nothing,
#   * with the 64-bit Mk4tcl it must read, change, repair and verify it.
# EXPECT_WIDE=1|0 in the environment makes the test insist on which Mk4tcl it found (CI does).
#   MKIT_MK4TCL=... tclsh tests/widefile.tcl
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) [expr {[info exists ::env(MKIT_BACKEND)] ? $::env(MKIT_BACKEND) : "standalone"}]
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc ok {name cond {info ""}} { global pass fail ; if {$cond} { incr pass } else { incr fail ; puts "FAIL $name $info" } }
proc err {script} { if {[catch {uplevel 1 $script} m]} { return $m } ; return "" }
proc slurp {f} { set h [open $f rb] ; set d [read $h] ; close $h ; return $d }
proc spit {f d} { set h [open $f wb] ; puts -nonewline $h $d ; close $h }
if {[mkitsql::db::available] eq "0"} { puts "no Metakit" ; exit 2 }
if {$::mk4kind eq "stand-in"} { puts "widefile: needs a real Mk4tcl (the stand-in does not write Metakit files); skipped" ; exit 0 }
set dir [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_widefile_[pid]
file delete -force $dir ; file mkdir $dir
set std $dir/std.mk ; set wide $dir/wide.mk

# an ordinary database made by the engine
set db [mkitsql::db::openFile $std -create]
mkitsql::run {CREATE TABLE t (id INT, name TEXT)} $db
mkitsql::run {INSERT INTO t VALUES (1,'one'),(2,'two'),(3,'three')} $db
mkitsql::db::commit $db
mkitsql::db::closeFile $db
set data [slurp $std]
ok "standard file has the old frame" [expr {[mkitsql::dbProblem $std] eq ""}]
ok "standard file is not wide" [expr {![mkitsql::db::isWide $std]}]
ok "standard headerInfo says wide 0" [expr {![dict get [mkitsql::db::headerInfo $std] wide]}]
spit $wide [mkitsql::db::wideConvert $data]
ok "converted file is wide" [mkitsql::db::isWide $wide]
ok "wide frame is recognised" [mkitsql::db::footerOkAt $wide [file size $wide] 1]
ok "wide frame is not a standard frame" [expr {![mkitsql::db::footerOkAt $wide [file size $wide] 0]}]
ok "dbProblem accepts the wide frame" [expr {[mkitsql::dbProblem $wide] eq ""}] [mkitsql::dbProblem $wide]
ok "headerInfo of a wide file" [expr {[dict get [mkitsql::db::headerInfo $wide] wide] && [dict get [mkitsql::db::headerInfo $wide] offset] == [file size $wide]}]
ok "wideHex" [mkitsql::db::wideHex [dict get [mkitsql::db::headerInfo $wide] header]]
# a damaged wide frame is noticed (cut, wrong tail types, root beyond the skip tail)
foreach {what cut} {cut-1 1 cut-9 9 cut-24 24} {
    spit $dir/c.mk [string range [slurp $wide] 0 end-$cut]
    ok "wide file $what is not intact" [expr {[mkitsql::dbProblem $dir/c.mk] ne ""}]
}
set w [slurp $wide] ; set n [string length $w]
spit $dir/c.mk [string range $w 0 [expr {$n-25}]]\x01[string range $w [expr {$n-23}] end]
ok "wrong skip tail type" [expr {[mkitsql::dbProblem $dir/c.mk] ne ""}]
spit $dir/c.mk [string range $w 0 [expr {$n-9}]]\x00[string range $w [expr {$n-7}] end]
ok "wrong commit tail type" [expr {[mkitsql::dbProblem $dir/c.mk] ne ""}]
file delete $dir/c.mk

set cap [mkitsql::db::wideCapable]
if {[info exists ::env(EXPECT_WIDE)]} { ok "the Mk4tcl is of the expected kind (EXPECT_WIDE=$::env(EXPECT_WIDE))" [expr {$cap == $::env(EXPECT_WIDE)}] "wideCapable = $cap" }
puts "wideCapable = $cap  ([expr {[info exists ::mk4kind] ? $::mk4kind : "?"}])"
ok "wideCapable is cached and stable" [expr {[mkitsql::db::wideCapable] eq $cap}]
ok "the probe leaves no file behind" [expr {[glob -nocomplain -directory [mkitsql::tmpDir] mkitsql-probe-*] eq ""}]
ok "fileLimit follows the library" [expr {[mkitsql::db::fileLimit] == ($cap ? (1 << 56) - 64 : 2147483647)}]

proc refused {file} {
    # a wide file the library cannot read: refused in every mode, and nothing is touched
    global dir
    set before [slurp $file]
    foreach mode {{} -readonly -unchecked -verify} {
        set rc [catch {mkitsql::db::openFile $file {*}$mode} m opts]
        ok "refused ($mode)" [expr {$rc && [lrange [dict get $opts -errorcode] 0 1] eq {MKIT WIDEFILE}}] "$rc $m"
        ok "message says what to do ($mode)" [string match "*atyr647/metakit*" $m]
    }
    ok "file untouched" [expr {[slurp $file] eq $before}]
    ok "no lock file left" [expr {![file exists $file.lock]}]
    ok "no commit record left" [expr {![file exists $file.commit]}]
    ok "no sum file made" [expr {![file exists $file.sum]}]
}
if {!$cap} {
    refused $wide
} else {
    # ---- the 64-bit Metakit: read, change, commit, repair, verify ----
    foreach mode {-readonly -verify {}} {
        set d [mkitsql::db::openFile $wide {*}$mode]
        set r [mkitsql::run {SELECT COUNT(*) AS c, MAX(name) AS m FROM t} $d]
        ok "wide file reads ($mode)" [expr {[dict get $r rows] eq {{3 two}}}] [dict get $r rows]
        mkitsql::db::closeFile $d
    }
    set d [mkitsql::db::openFile $wide]
    mkitsql::run {INSERT INTO t VALUES (4,'four')} $d
    mkitsql::db::commit $d
    mkitsql::db::closeFile $d
    ok "wide file stays wide after a commit" [mkitsql::db::isWide $wide]
    ok "and its frame is valid" [expr {[mkitsql::dbProblem $wide] eq ""}] [mkitsql::dbProblem $wide]
    set d [mkitsql::db::openFile $wide -readonly]
    ok "the commit is there" [expr {[dict get [mkitsql::run {SELECT COUNT(*) AS c FROM t} $d] rows] eq {4}}]
    mkitsql::db::closeFile $d
    # an interrupted commit: junk after the last good tails + the record that says what to put back
    set good [slurp $wide] ; set info [mkitsql::db::headerInfo $wide]
    spit $wide $good[string repeat J 5000]
    spit [mkitsql::db::commitRecord $wide] "[dict get $info header] [dict get $info size]"
    set d [mkitsql::db::openFile $wide]
    ok "interrupted commit on a wide file is put right" [expr {[slurp $wide] eq $good}] "[file size $wide] vs [string length $good]"
    ok "the repair is reported" [expr {[mkitsql::db::repairedNote $d] ne ""}]
    ok "and the data is intact" [expr {[dict get [mkitsql::run {SELECT COUNT(*) AS c FROM t} $d] rows] eq {4}}]
    mkitsql::db::closeFile $d
    # junk after the tails and NO record: the frame check says so instead of guessing
    spit $wide $good[string repeat J 100]
    ok "junk after a wide frame is noticed" [expr {[mkitsql::dbProblem $wide] ne ""}]
    spit $wide $good
    # the library of a program that cannot read wide files, simulated: MKIT_WIDE=0 in a new process
    set out [lindex [split [string trim [exec [info nameofexecutable] $here/widefile_child.tcl $wide 2>@1]] "\n"] end]
    ok "a program told MKIT_WIDE=0 refuses the file" [string match "refused *" $out] $out
    # the sum and the proof
    set d [mkitsql::db::openFile $wide -verify]
    ok "-verify of a wide file gives a level" [expr {[lindex [mkitsql::db::integrityOf $d] 1] in {proven evidence}}] [mkitsql::db::integrityOf $d]
    mkitsql::db::closeFile $d
}

# ---- the column guard, with a small limit (it does not depend on the Metakit that is loaded) ----
set ::mkitsql::db::wideCap 1                      ;# switch the guard on whatever the library, for this part
set ::mkitsql::db::maxColumnBytes 20000 ; set ::mkitsql::db::guardSlack 0
set g $dir/guard.mk
set db [mkitsql::db::openFile $g -create]
mkitsql::db::createView $db t {{k I {}} {s S {}} {b B {}}}
set blob [string repeat x 999]
set n 0 ; set code ""
for {set i 0} {$i < 40} {incr i} {
    if {[catch {mkitsql::db::appendRow $db.t {k s} [list $i $blob]} m opts]} { set code [dict get $opts -errorcode] ; break }
    incr n
}
ok "a column past its limit is refused with COLUMNFULL" [expr {[lrange $code 0 1] eq {MKIT COLUMNFULL}}] "code=$code after $n rows"
ok "the refusal comes near the limit" [expr {$n >= 19 && $n <= 20}] $n
ok "the refused row was not added" [expr {[mkitsql::db::size $db.t] == $n}]
ok "the message names the column" [string match "*Column s*" $m] $m
# an update that grows the column is checked too; a different column of the same table is still fine
set rc [catch {mkitsql::db::setCell $db.t 0 s [string repeat y 999]} m2 opts2]
ok "setCell checked" [expr {$rc && [lrange [dict get $opts2 -errorcode] 0 1] eq {MKIT COLUMNFULL}}] $m2
ok "other columns are unaffected" [expr {![catch {mkitsql::db::setCell $db.t 0 b small}]}]
# the count survives a commit and is dropped with a rollback
mkitsql::db::commit $db
ok "still refused after a commit" [catch {mkitsql::db::appendRow $db.t {k s} [list 99 $blob]}]
mkitsql::db::rollback $db
mkitsql::db::closeFile $db
set ::mkitsql::db::maxColumnBytes 2147483647 ; set ::mkitsql::db::guardSlack 4194304
set ::mkitsql::db::wideCap $cap

file delete -force $dir
puts "widefile: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
