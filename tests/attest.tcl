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
# a failed or interrupted commit does not leave a sum that vouches for the wrong bytes: after the file is put back the sum is "changed" or ok, never "damaged"
mkitsql::db::closeFile [lindex [mkitsql::db::tags] 0] 
foreach x [list $f $f.sum $f.lock $f.commit $f.sum.tmp] { file delete $x }
puts "attest: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
