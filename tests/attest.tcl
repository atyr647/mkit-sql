# -verify as a proof: the <file>.sum checksum (MK Studio's own format) written after every commit, checked at open.   tclkit tests/attest.tcl
#   proven   the sum matched: the file is byte for byte what the last commit left
#   evidence the file was read in a helper process without trouble (no proof)
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_att_[pid].mk
foreach x [list $f $f.sum $f.lock $f.commit] { file delete $x }
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" } }
proc q {sql} { mkitsql::run $sql $::db }
proc err {script} { if {[catch {uplevel 1 $script} e opts]} { return [lrange [dict get $opts -errorcode] 0 end] } ; return OK }
proc slurp {p} { set h [open $p rb] ; set d [read $h] ; close $h ; return $d }
proc spit {p d} { set h [open $p wb] ; puts -nonewline $h $d ; close $h }
set studio [expr {$::mkitsql::backend eq "studio"}]
set db [mkitsql::db::openFile $f -create]
q "CREATE TABLE t (id INT, s TEXT)"
for {set i 0} {$i < 500} {incr i} { mkitsql::db::appendRow $db.t {id s} [list $i "row $i"] ; mkitsql::db::touch $db }
q COMMIT
if {!$studio} {
    check "the sum exists after a commit" [file exists $f.sum] 1
    lassign [slurp $f.sum] crc size mtime
    check "its crc32 is the file's" $crc [format %08x [zlib crc32 [slurp $f]]]
    check "its size" $size [file size $f]
    check "its time" $mtime [file mtime $f]
}
mkitsql::db::closeFile $db
# the sum is written in the same second as the file's last change, so it cannot yet tell a foreign write from damage: a flip right now is "changed"
if {!$studio} {
    set good0 [slurp $f] ; set mt0 [file mtime $f]
    set pos0 [expr {[file size $f] / 2}]
    spit $f [string replace $good0 $pos0 $pos0 [binary format c [expr {([scan [string index $good0 $pos0] %c] + 1) & 255}]]] ; file mtime $f $mt0
    check "same second: not called damage" [mkitsql::db::sumCheck $f] changed
    spit $f $good0 ; file mtime $f $mt0
}
after 1300                                   ;# a later second: the next open that finds the sum intact stamps it, and from then on damage is unambiguous
set db [mkitsql::db::openFile $f] ; mkitsql::db::closeFile $db
# an untouched file: proven
set db [mkitsql::db::openFile $f -readonly -verify]
check "untouched: proven" [lindex [mkitsql::db::integrityOf $db] 1] [expr {$studio && ![llength [info commands ::store::sumCheck]] ? "evidence" : "proven"}]
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f -readonly]
check "no -verify: no level" [lindex [mkitsql::db::integrityOf $db] 1] ""
mkitsql::db::closeFile $db
if {$studio && ![llength [info commands ::store::sumCheck]]} { puts "(this MK Studio store has no checksum: the rest is skipped)" ; puts "attest: $pass passed, $fail failed" ; exit [expr {$fail ? 1 : 0}] }
# one byte flipped, size and time kept: PROVEN damaged, refused (writable and read-only), -unchecked opens it
set good [slurp $f] ; set mt [file mtime $f]
set pos [expr {[file size $f] / 2}]
set bad [string replace $good $pos $pos [binary format c [expr {([scan [string index $good $pos] %c] + 1) & 255}]]]
spit $f $bad ; file mtime $f $mt
check "flipped byte: refused for writing" [lrange [err {mkitsql::db::openFile $f}] 0 1] {MKIT DAMAGED}
check "... and by -verify read-only" [lrange [err {mkitsql::db::openFile $f -readonly -verify}] 0 1] {MKIT DAMAGED}
check "... with the reason" [lindex [err {mkitsql::db::openFile $f}] 2] checksum
check "... and no lock left behind" [file exists $f.lock] 0
# the original bytes: fine again
spit $f $good ; file mtime $f $mt
set db [mkitsql::db::openFile $f -readonly -verify]
check "restored: proven again" [lindex [mkitsql::db::integrityOf $db] 1] proven
mkitsql::db::closeFile $db
# a file another program changed (size differs): the sum no longer applies - no proof, but no false alarm
spit $f $good ; file mtime $f [expr {$mt + 100}]
set db [mkitsql::db::openFile $f -readonly -verify]
check "changed time: evidence only" [lindex [mkitsql::db::integrityOf $db] 1] evidence
check "... state" [lindex [mkitsql::db::integrityOf $db] 0] [expr {$studio ? "" : "changed"}]
mkitsql::db::closeFile $db
# a commit re-attests
file delete $f.lock
set db [mkitsql::db::openFile $f]
mkitsql::db::appendRow $db.t {id s} [list 9999 x] ; mkitsql::db::touch $db ; q COMMIT
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f -readonly -verify]
check "after a commit: proven" [lindex [mkitsql::db::integrityOf $db] 1] proven
mkitsql::db::closeFile $db
if {!$studio} {
    # no sum at all (a file made by something else): evidence
    file delete $f.sum
    set db [mkitsql::db::openFile $f -readonly -verify]
    check "no sum: evidence" [lindex [mkitsql::db::integrityOf $db] 1] evidence
    mkitsql::db::closeFile $db
    # not covered above the limit
    set mkitsql::db::sumLimit 0
    set db [mkitsql::db::openFile $f] ; mkitsql::db::appendRow $db.t {id s} [list 10000 y] ; mkitsql::db::touch $db ; q COMMIT ; mkitsql::db::closeFile $db
    check "sumLimit 0: no sum written" [file exists $f.sum] 0
    set mkitsql::db::sumLimit 512
    # MK Studio's own check agrees with ours (a store that knows the sum)
    set db [mkitsql::db::openFile $f] ; mkitsql::db::appendRow $db.t {id s} [list 10001 z] ; mkitsql::db::touch $db ; q COMMIT ; mkitsql::db::closeFile $db
    if {[info exists ::env(MKSTUDIO_DIR)] && [file exists $::env(MKSTUDIO_DIR)/mkstudio.vfs/lib/app-mkstudio/store.tcl]} {
        set script $tmp/mkitsql_att_child_[pid].tcl
        spit $script "namespace eval ::store {}\nsource \[lindex \$argv 0\]\nputs \[::store::sumCheck \[lindex \$argv 1\]\]"
        set out [exec [info nameofexecutable] $script $::env(MKSTUDIO_DIR)/mkstudio.vfs/lib/app-mkstudio/store.tcl $f 2>@1]
        check "MK Studio's sumCheck accepts our sum" [lindex [split [string trim $out] "\n"] end] ok
        file delete $script
    }
}
# the sum file is untrusted input: malformed contents never stop the database from opening
if {!$studio} {
    foreach {label content} [list empty "" brace "3716c223 8546 \{1793" quote "3716c223 8546 \"17" four "a b c d" words "xyz 1 2" short "1 2"] {
        spit $f.sum $content
        set rc [catch {set d2 [mkitsql::db::openFile $f -readonly -verify]} m]
        check "malformed sum ($label): the file still opens" $rc 0
        if {!$rc} { check "... as evidence" [lindex [mkitsql::db::integrityOf $d2] 1] evidence ; mkitsql::db::closeFile $d2 }
    }
    # an upper-case crc written by another program is the same number
    set db [mkitsql::db::openFile $f] ; mkitsql::db::appendRow $db.t {id s} [list 20000 q] ; mkitsql::db::touch $db ; mkitsql::db::commit $db ; mkitsql::db::closeFile $db
    lassign [slurp $f.sum] crc size mtime
    spit $f.sum "[string toupper $crc] $size $mtime"
    check "upper-case crc: ok" [mkitsql::db::sumCheck $f] ok
    # a symbolic link in the place of the temporary file must not be written through
    set victim $tmp/mkitsql_att_victim_[pid].txt ; spit $victim "precious"
    file delete $f.sum.tmp ; file link -symbolic $f.sum.tmp $victim
    set db [mkitsql::db::openFile $f] ; mkitsql::db::appendRow $db.t {id s} [list 20001 r] ; mkitsql::db::touch $db ; mkitsql::db::commit $db ; mkitsql::db::closeFile $db
    check "a link as the temporary sum file: the target is untouched" [slurp $victim] precious
    file delete $victim $f.sum.tmp
    # a sum file that is not a small plain file is ignored (a FIFO would block, a huge one would be read whole)
    file delete $f.sum ; file mkdir $f.sum
    check "a directory as the sum: ignored" [mkitsql::db::sumCheck $f] none
    file delete -force $f.sum
    set fifo 0 ; if {![catch {exec mkfifo $f.sum}]} { set fifo 1 }
    if {$fifo} {
        set script $tmp/mkitsql_att_fifo_[pid].tcl
        spit $script "set ::env(MKIT_BACKEND) standalone\nsource $here/mk4load.tcl\nsource $here/loadengine.tcl\nset d \[mkitsql::db::openFile \[lindex \$argv 0\] -readonly -verify\]\nputs \"opened \[lindex \[mkitsql::db::integrityOf \$d\] 1\]\""
        set rc [catch {exec timeout 30 [info nameofexecutable] $script $f 2>@1} out]
        check "a FIFO as the sum does not block the open" [string match "*opened evidence*" $out] 1
        file delete $script
    }
    file delete -force $f.sum
    set db [mkitsql::db::openFile $f] ; mkitsql::db::appendRow $db.t {id s} [list 20002 s] ; mkitsql::db::touch $db ; mkitsql::db::commit $db ; mkitsql::db::closeFile $db
    # the sum is removed when a commit starts: a commit killed half way leaves no sum that vouches for the old bytes
    set mkitsql::db::durable 0
    set db [mkitsql::db::openFile $f] ; mkitsql::db::appendRow $db.t {id s} [list 20003 t] ; mkitsql::db::touch $db
    set seen ""
    rename ::mkitsql::db::endCommit ::mkitsql::db::endCommit_orig
    proc ::mkitsql::db::endCommit {path} { set ::seen [::file exists $path.sum] ; ::mkitsql::db::endCommit_orig $path }
    mkitsql::db::commit $db
    rename ::mkitsql::db::endCommit {} ; rename ::mkitsql::db::endCommit_orig ::mkitsql::db::endCommit
    check "no sum during a commit" $seen 0
    check "a sum after it" [file exists $f.sum] 1
    mkitsql::db::closeFile $db
    set mkitsql::db::durable 1
}
# headroom helpers fail cleanly
check "fileHeadroom of an unknown database" [string match "*Unknown database*" [err {mkitsql::db::fileHeadroom nosuch}]] 0
catch {mkitsql::db::fileHeadroom nosuch} hm ; check "... message" [string match "Unknown database*" $hm] 1
catch {mkitsql::db::nearLimit [lindex [mkitsql::db::tags] 0] abc} hm ; check "nearLimit with a bad fraction" [string match "*fraction*" $hm] 1
# a failed or interrupted commit does not leave a sum that vouches for the wrong bytes: after the file is put back the sum is "changed" or ok, never "damaged"
mkitsql::db::closeFile [lindex [mkitsql::db::tags] 0] 
foreach x [list $f $f.sum $f.lock $f.commit $f.sum.tmp] { file delete $x }
# a file no commit record can describe (no Metakit header at offset 0): its old sum does not outlive a commit either (0.6.0: it used to stay)
if {!$studio} {
    set g $tmp/mkitsql_att_foreign_[pid].bin
    spit $g "no Metakit header here, just bytes"
    mkitsql::db::sumWrite $g
    check "foreign file: a sum to begin with" [file exists $g.sum] 1
    check "foreign file: no commit record" [mkitsql::db::beginCommit $g] 0
    check "foreign file: the old sum is gone once the commit begins" [file exists $g.sum] 0
    check "foreign file: no record file" [file exists $g.commit] 0
    foreach x [list $g $g.sum $g.commit] { file delete $x }
}
puts "attest: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
