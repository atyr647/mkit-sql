# Damaged files and crashes.
#   * Mk4tcl "opens" a truncated or damaged file as an empty database, and saving would overwrite it: mkit-sql checks
#     the file's frame and refuses (MKIT DAMAGED) - the file is not touched and no lock is left behind
#   * a process killed (kill -9) while committing leaves a file that is always a whole number of committed batches
#   tclsh tests/damage.tcl [crash trials]
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set trials [expr {$argc > 0 ? [lindex $argv 0] : 12}]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set area $tmp/mkitsql_damage_[pid]
file delete -force $area ; file mkdir $area
proc lmap_ {l spec} { lassign $spec v b ; set o {} ; foreach item $l { lappend o [apply [list $v $b] $item] } ; return $o }
proc slurp {f} { set h [open $f rb] ; set d [read $h] ; close $h ; return $d }
proc spit {f d} { set h [open $f wb] ; puts -nonewline $h $d ; close $h }

# ---- a good file, written by mkit-sql --------------------------------------------------------------------------------
set good $area/good.mk
set tag [mkitsql::db::openFile $good -create]
mkitsql::run "CREATE TABLE t (id INT, name TEXT, kids TABLE (k TEXT))" $tag
set v {}
for {set i 0} {$i < 800} {incr i} { lappend v "($i, 'name$i')" }
mkitsql::run "INSERT INTO t (id, name) VALUES [join $v ,]" $tag
mkitsql::run "INSERT INTO t\[5\].kids VALUES ('a'), ('b')" $tag
mkitsql::run COMMIT $tag
mkitsql::db::closeFile $tag
set data [slurp $good] ; set size [string length $data]
check good_file_is_intact [mkitsql::dbProblem $good] ""
check empty_file_is_fine [expr {[spit $area/e.mk ""] eq "" ? [mkitsql::dbProblem $area/e.mk] : "x"}] ""
check missing_file_is_fine [mkitsql::dbProblem $area/nonexistent.mk] ""

proc expectDamaged {name file args} {
    # opens (read-write, read-only, create) must all be refused; the file and its folder stay untouched
    set before [slurp $file]
    foreach mode [list {} -readonly -create] {
        set rc [catch {mkitsql::db::openFile $file {*}$mode} msg opts]
        check "$name: open $mode refused" [list $rc [lrange [dict get $opts -errorcode] 0 1]] {1 {MKIT DAMAGED}}
    }
    check "$name: file untouched" [slurp $file] $before
    check "$name: no lock left" [file exists $file.lock] 0
    set made {} ; foreach g [glob -nocomplain -directory [file dirname $file] [file tail $file]*] { lappend made [file normalize $g] }
    check "$name: nothing else created" [lsort $made] [list [file normalize $file]]
}
proc variant {name data} {
    set f $::area/v_$name.mk
    spit $f $data
    expectDamaged $name $f
    return $f
}
set f [variant truncated_half [string range $data 0 [expr {$size / 2}]]]
check truncated_message [string match "*truncated*" [mkitsql::dbProblem $f]] 1
variant truncated_tail [string range $data 0 [expr {$size - 9}]]
variant truncated_20 [string range $data 0 19]
variant garbage_head [string repeat X 64][string range $data 64 end]
variant flipped_footer [string range $data 0 [expr {$size - 17}]][string repeat \xff 16]
# a file LONGER than its header says is what an interrupted commit leaves (the data is appended, the header written last):
# read-only it is refused (it would look like an empty database); opened for writing the unfinished tail is cut back
set f $::area/v_extended.mk
spit $f "${data}ABCDE"
check "extended: read-only refused" [expr {[catch {mkitsql::db::openFile $f -readonly} m opts] ? [lrange [dict get $opts -errorcode] 0 1] : "opened"}] {MKIT DAMAGED}
set tg [mkitsql::db::openFile $f]
check "extended: opened for writing, the unfinished tail was discarded" [list [mkitsql::db::repairedNote $tg] [slurp $f]] [list "The unfinished end of an interrupted commit was discarded." $data]
mkitsql::db::closeFile $tg
variant header_size_wrong [string range $data 0 3]\x00\x00\x00\x07[string range $data 8 end]
set f [variant not_a_db_but_jl_prefix "JL\x1a\x00[string repeat z 100]"]
# a plain text file and a non-Metakit binary: caught after opening (no tables, no signature)
spit $area/text.txt "hello, this is not a database\n"
foreach mode [list {} -readonly] {
    set rc [catch {mkitsql::db::openFile $area/text.txt {*}$mode} msg opts]
    check "text file open $mode refused" [list $rc [lindex [dict get $opts -errorcode] 1]] {1 DAMAGED}
}
check text_untouched [slurp $area/text.txt] "hello, this is not a database\n"
check text_no_lock [file exists $area/text.txt.lock] 0
# -unchecked is an explicit override
set rc [catch {mkitsql::db::openFile $area/v_truncated_half.mk -readonly -unchecked} t2]
check unchecked_opens [list $rc [mkitsql::db::views $t2]] {0 {}}
mkitsql::db::closeFile $t2

# a zero-length file is a new database
spit $area/zero.mk ""
set t3 [mkitsql::db::openFile $area/zero.mk] ; mkitsql::db::closeFile $t3
check zero_length_opens 1 1

# ---- every byte of the frame: a change is noticed ----------------------------------------------------------------------------
set undetected {}
proc ::mkitsql::dbProblem_str {bytes} { set f $::area/probe.mk ; spit $f $bytes ; return [mkitsql::dbProblem $f] }
# (bytes 0-1, the signature, are not judged by the frame check: a file without it is treated like a starkit)
for {set off 2} {$off < 8} {incr off} {
    foreach delta {1 0x80 0xff} {
        set b $data
        binary scan [string index $b $off] c old
        set b [string replace $b $off $off [binary format c [expr {($old ^ $delta) & 0xff}]]]
        if {[mkitsql::dbProblem_str $b] eq ""} { lappend undetected "header\[$off\]^$delta" }
    }
}
# footer: the flag words and the footer's own position are checked; the table-of-contents length and position (bytes 9-15)
# can legitimately vary, so they are not judged
for {set off 0} {$off < 9} {incr off} {
    foreach delta {1 0x80 0xff} {
        set pos [expr {$size - 16 + $off}]
        binary scan [string index $data $pos] c old
        set b [string replace $data $pos $pos [binary format c [expr {($old ^ $delta) & 0xff}]]]
        if {[mkitsql::dbProblem_str $b] eq ""} { lappend undetected "footer\[$off\]^$delta" }
    }
}
check frame_changes_all_detected $undetected {}
# truncation at any length is detected
set missed 0
foreach cut {1 5 8 16 23 24 100 1000 5000 20000} {
    if {$cut < $size && [mkitsql::dbProblem_str [string range $data 0 [expr {$cut - 1}]]] eq "" && $cut >= 2} { incr missed }
}
check truncation_at_any_length_detected $missed 0

# ---- a valid file is never flagged: the frame stays valid through every kind of commit --------------------------------------------------
set vf $area/valid.mk
set tg [mkitsql::db::openFile $vf -create]
set badFrames {}
proc frameOk {label} { set w [mkitsql::dbProblem $::vf] ; if {$w ne ""} { lappend ::badFrames "$label: $w" } }
mkitsql::run "CREATE TABLE a (id INT, s TEXT, kids TABLE (k TEXT))" $tg ; mkitsql::run COMMIT $tg ; frameOk create
for {set r 0} {$r < 6} {incr r} {
    set v {}
    for {set i 0} {$i < 400} {incr i} { lappend v "([expr {$r * 400 + $i}], 'row [expr {$r * 400 + $i}]')" }
    mkitsql::run "INSERT INTO a (id, s) VALUES [join $v ,]" $tg ; mkitsql::run COMMIT $tg ; frameOk insert$r
    mkitsql::run "UPDATE a SET s = s || 'x' WHERE id % 3 = 0" $tg ; mkitsql::run COMMIT $tg ; frameOk update$r
    set mkitsql::bulkMin 5
    mkitsql::run "DELETE FROM a WHERE id % 5 = 0" $tg ; mkitsql::run COMMIT $tg ; frameOk bulkdelete$r
    set mkitsql::bulkMin 20000
    mkitsql::run "INSERT INTO a\[0\].kids VALUES ('k$r')" $tg ; mkitsql::run COMMIT $tg ; frameOk subview$r
}
mkitsql::run "ALTER TABLE a ADD COLUMN c INT" $tg ; mkitsql::run COMMIT $tg ; frameOk addcol
mkitsql::run "ALTER TABLE a RENAME COLUMN c TO d" $tg ; mkitsql::run COMMIT $tg ; frameOk rename
mkitsql::run "CREATE TABLE b AS SELECT id, s FROM a" $tg ; mkitsql::run COMMIT $tg ; frameOk ctas
mkitsql::run "DROP TABLE b" $tg ; mkitsql::run COMMIT $tg ; frameOk drop
mkitsql::run "DROP TABLE a" $tg ; mkitsql::run COMMIT $tg ; frameOk dropall
mkitsql::db::closeFile $tg
frameOk closed
check valid_files_never_flagged $badFrames {}
set tg [mkitsql::db::openFile $vf] ; mkitsql::db::closeFile $tg
check valid_file_reopens 1 1

# ---- the other byte order ("LJ") is judged the same way -------------------------------------------------------------------------
proc swapWord {w} { binary scan $w H8 h ; return [binary format H8 [string range $h 6 7][string range $h 4 5][string range $h 2 3][string range $h 0 1]] }
set le "LJ[string range $data 2 3][swapWord [string range $data 4 7]][string range $data 8 end-16][swapWord [string range $data end-15 end-12]][swapWord [string range $data end-11 end-8]][swapWord [string range $data end-7 end-4]][swapWord [string range $data end-3 end]]"
check little_endian_intact [mkitsql::dbProblem_str $le] ""
check little_endian_truncated [expr {[mkitsql::dbProblem_str [string range $le 0 end-9]] ne ""}] 1

# ---- files that are not standalone databases: a tclkit carries its database at the end ------------------------------------------------
set exe [info nameofexecutable]
if {[file exists $exe] && [catch {slurp $exe} exeData] == 0 && [string range $exeData 0 1] ne "JL"} {
    check executable_not_judged_by_frame [mkitsql::dbProblem $exe] ""
    set t4 [mkitsql::db::openFile $exe -readonly]
    check executable_opens_readonly [expr {[llength [mkitsql::db::views $t4]] > 0}] 1
    mkitsql::db::closeFile $t4
}

# ---- damage inside the data: Metakit crashes or hangs, so an untrusted file is checked in a throw-away process ----------------------------------------
check verify_good_file [mkitsql::verifyProblem $good] ""
set tv [mkitsql::db::openFile $good -readonly -verify] ; mkitsql::db::closeFile $tv
check open_verify_good_file 1 1
set firstRefused "" ; set survived 0 ; set refused 0 ; set readable 0 ; set unreadable 0
expr {srand(20260101)}
set ntrial [expr {$trials > 20 ? 20 : $trials}]
for {set k 0} {$k < $ntrial} {incr k} {
    set b $data
    for {set j 0} {$j < 1 + int(rand() * 12)} {incr j} {
        set pos [expr {8 + int(rand() * ($size - 25))}]
        set b [string replace $b $pos $pos [binary format c [expr {int(rand() * 256)}]]]
    }
    set f $area/fz_$k.mk ; spit $f $b
    set why [mkitsql::verifyProblem $f 4]
    if {$why ne ""} {
        incr refused ; if {$firstRefused eq ""} { set firstRefused $area/refused.mk ; spit $firstRefused $b }
        set verdict [expr {[catch {mkitsql::db::openFile $f -readonly -verify} m opts] ? [lrange [dict get $opts -errorcode] 0 1] : "opened"}]
        if {$::tcl_platform(os) eq "Linux" || $verdict eq {MKIT DAMAGED}} { check "fuzzed file $k: refused by open -verify" $verdict {MKIT DAMAGED} } else { puts "NOTE: fuzzed file $k was refused by the first check and opened by the second (non-deterministic Metakit read on $::tcl_platform(os))" }
    } else {
        # the helper read everything without trouble: reading it here must be safe too
        incr survived
        if {[catch {
            set tg [mkitsql::db::openFile $f -readonly -verify]
            foreach v [mkitsql::db::views $tg] { mkitsql::db::rows $tg.$v [lmap_ [lsearch -all -inline -not -index 1 -exact [mkitsql::db::layout $tg.$v] V] {c {lindex $c 0}}] 0 100000 }
            mkitsql::db::closeFile $tg
        } msg]} { incr unreadable ; puts "file $k verified OK but failed to read: [string range $msg 0 80]" } else { incr readable }
    }
    file delete $f
}
check verify_verdicts_add_up [expr {$survived + $refused}] $ntrial
# Metakit reads damaged data non-deterministically (the same bytes can loop on one read and not on the next), so the verifier is a filter, not a proof:
# strict on Linux, reported only elsewhere (seen on macOS CI)
if {$::tcl_platform(os) eq "Linux"} { check verified_files_are_readable [list $readable $unreadable] [list $survived 0] } elseif {$unreadable} { puts "NOTE: $unreadable verified file(s) were not readable on $::tcl_platform(os) - the verifier is a filter, not a proof" }
puts "(of $ntrial files with random damage inside the data: $refused refused by the verifier, $survived read fine)"
if {$firstRefused ne ""} {
    set refusedAgain [catch {mkitsql::dbVerify $firstRefused} m]
    if {$refusedAgain} { check verify_message [string match "*failed verification*could crash this program*" $m] 1 } \
    elseif {$::tcl_platform(os) eq "Linux"} { check verify_message 0 1 } else { puts "NOTE: the file the verifier refused once was accepted the second time ($::tcl_platform(os))" }
}

# ---- kill -9 in the middle of commits ---------------------------------------------------------------------------------------------------
set me [info nameofexecutable]
set bad 0 ; set torn 0 ; set stale 0 ; set tn 0
if {$::tcl_platform(platform) ne "windows"} {
    for {set trial 0} {$trial < $trials} {incr trial} {
        set f $area/crash.mk
        if {$trial == 0} { file delete $f $f.lock }
        set ch [open |[list $me $here/damage_child.tcl $f] r]
        fconfigure $ch -blocking 0
        set cpid [pid $ch]
        set target [expr {1 + int(rand() * 3)}] ; set last 0 ; set t0 [clock milliseconds]
        while {$last < $target && [clock milliseconds] - $t0 < 30000} {
            if {[gets $ch line] > 0 && [regexp {committed (\d+)} $line -> kk]} { set last $kk }
            after 2
        }
        after [expr {int(rand() * 300)}]
        catch {exec kill -9 $cpid} ; catch {close $ch}
        # a signal is delivered a moment later: wait until the process is really gone
        set w0 [clock milliseconds]
        while {[mkitsql::pidAlive $cpid] && [clock milliseconds] - $w0 < 3000} { after 5 }
        if {[file exists $f.lock]} { incr stale }
        if {[mkitsql::dbProblem $f] ne ""} { incr bad ; puts "trial $trial: [mkitsql::dbProblem $f]" ; continue }
        set tg [mkitsql::db::openFile $f]            ;# takes over the dead process's lock
        set n [lindex [lindex [dict get [mkitsql::run "SELECT COUNT(*) FROM t" $tg] rows] 0] 0]
        set sum [lindex [lindex [dict get [mkitsql::run "SELECT SUM(id) FROM t" $tg] rows] 0] 0]
        mkitsql::db::closeFile $tg
        incr tn
        if {$n % 5000 != 0 || ($n > 0 && $sum != $n * ($n - 1) / 2)} { incr torn ; puts "trial $trial: torn: $n rows, sum $sum" }
    }
    check crash_files_never_damaged $bad 0
    check crash_files_never_torn $torn 0
    check crash_trials_ran [expr {$tn >= $trials - 1}] 1
    check crash_left_stale_locks_that_were_taken_over [expr {$stale > 0 || $trials < 4}] 1
} else { puts "(crash trials skipped on Windows)" }

foreach t [mkitsql::db::tags] { catch {mkitsql::db::closeFile $t} }       ;# (macOS: Metakit crashed at exit with a handle left open)
file delete -force $area
puts "$pass passed, $fail failed"
flush stdout
exit [expr {$fail ? 1 : 0}]
