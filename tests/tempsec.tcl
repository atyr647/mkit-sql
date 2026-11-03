# Temporary (spill) files: private folder, exclusive 0600 files, unpredictable names, nothing left behind,
# and abandoned folders from crashed runs are swept - without ever touching anything that is not ours.
#   tclsh tests/tempsec.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
if {$::tcl_platform(platform) eq "windows"} { puts "skipped on Windows" ; exit 0 }
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set area $tmp/mkitsql_tempsec_[pid]
file delete -force $area ; file mkdir $area
set mkitsql::tempDir $area
set f $area/db.mk
set db [mkitsql::db::openFile $f -create]
proc q {sql} { mkitsql::run $sql $::db }
q "CREATE TABLE t (id INT, s TEXT)"
set v {}
for {set i 0} {$i < 300} {incr i} { lappend v "($i, 'row$i')" }
q "INSERT INTO t VALUES [join $v ,]"
proc entries {} { lsort [glob -nocomplain -directory $::area mkitsql*] }
set mkitsql::memBytes 1 ; set mkitsql::chunk 5

# ---- while a statement spills: folder is private, files are 0600, names random ---------------------------------
set ::seen {}
set mkitsql::progressHook {apply {{} {
    foreach d [glob -nocomplain -directory $::area mkitsql-*] {
        set files [glob -nocomplain -directory $d *]
        if {[llength $files] && ![dict exists $::seen $d]} {
            dict set ::seen $d [list [file type $d] [file owned $d] [format %o [expr {[file attributes $d -permissions] & 511}]] \
                [lsort -unique [lmap_ $files {f {format %o [expr {[file attributes $f -permissions] & 511}]}}]] \
                [lsort -unique [lmap_ $files {f {file owned $f}}]] [llength $files]]
        }
    }
}}}
proc lmap_ {l spec} { lassign $spec v b ; set o {} ; foreach item $l { lappend o [apply [list $v $b] $item] } ; return $o }
q "SELECT s FROM t ORDER BY s DESC"
set mkitsql::progressHook ""
check seen_one_folder [dict size $::seen] 1
set d [lindex [dict keys $::seen] 0]
check folder_name [regexp {^mkitsql-[A-Za-z0-9_]+-\d+-\d+-[0-9a-f]{16}$} [file tail $d]] 1
check folder_has_our_namespace [string match "*-[pid]-[mkitsql::pidNs]-*" [file tail $d]] 1
check folder_has_our_pid [string match "*-[pid]-*" [file tail $d]] 1
lassign [dict get $::seen $d] type owned perm fperms fowned nfiles
check folder_is_directory $type directory
check folder_owned $owned 1
check folder_private $perm 700
check files_private $fperms 600
check files_owned $fowned 1
check nothing_left_behind [entries] {}

# ---- different runs, different names -----------------------------------------------------------------------------------
set names {}
for {set i 0} {$i < 5} {incr i} { lappend names [mkitsql::spillDir] ; mkitsql::spillCleanup }
check names_unique [llength [lsort -unique $names]] 5
check names_removed [entries] {}

# ---- exclusive creation: an existing file or a (dangling) link is never opened -------------------------------------------
set d [mkitsql::spillDir]
set victim $area/victim.txt
set fh [open $victim w] ; puts $fh "precious" ; close $fh
file link -symbolic $d/000001.spill $victim
check excl_symlink_refused [expr {[catch {mkitsql::spillOpenW $d/000001.spill} m] ? "refused" : "opened"}] refused
set fh [open $victim] ; set got [string trim [read $fh]] ; close $fh
check excl_symlink_target_intact $got "precious"
exec ln -s $area/does_not_exist $d/000002.spill
check excl_dangling_refused [expr {[catch {mkitsql::spillOpenW $d/000002.spill} m] ? "refused" : "opened"}] refused
check excl_dangling_target_not_created [file exists $area/does_not_exist] 0
set fh [open $d/000003.spill w] ; close $fh
check excl_existing_refused [expr {[catch {mkitsql::spillOpenW $d/000003.spill} m] ? "refused" : "opened"}] refused
mkitsql::spillCleanup
check cleanup_removes_planted_links [entries] {}
check victim_survived [file exists $victim] 1

# ---- a planted link or folder at the chosen name is skipped ------------------------------------------------------------
set ::picks {}
rename ::mkitsql::randHex ::mkitsql::randHex_real
proc ::mkitsql::randHex {n} { if {[llength $::picks]} { set x [lindex $::picks 0] ; set ::picks [lrange $::picks 1 end] ; return $x } ; return [::mkitsql::randHex_real $n] }
set want1 mkitsql-[mkitsql::userTag]-[pid]-[mkitsql::pidNs]-aaaaaaaaaaaaaaaa
set want2 mkitsql-[mkitsql::userTag]-[pid]-[mkitsql::pidNs]-bbbbbbbbbbbbbbbb
exec ln -s $area/elsewhere $area/$want1
file mkdir $area/$want2
set ::picks {aaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbb}
set d [mkitsql::spillDir]
check planted_names_skipped [expr {[file tail $d] ne $want1 && [file tail $d] ne $want2}] 1
check planted_link_untouched [file type $area/$want1] link
check planted_dir_untouched [file isdirectory $area/$want2] 1
mkitsql::spillCleanup
file delete $area/$want1 ; file delete $area/$want2
rename ::mkitsql::randHex {}
rename ::mkitsql::randHex_real ::mkitsql::randHex

# ---- sweeping abandoned folders ---------------------------------------------------------------------------------------------
proc mkdirWith {name files} { file mkdir $::area/$name ; foreach f $files { set fh [open $::area/$name/$f w] ; puts $fh x ; close $fh } }
set u [mkitsql::userTag]
mkdirWith mkitsql-$u-999999-0123456789abcdef {000001.spill 000002.spill}        ;# dead process
mkdirWith mkitsql-$u-1-0123456789abcdef {000001.spill}                          ;# pid 1 is alive and the folder is fresh
mkdirWith mkitsql-$u-1-1111111111111111 {000001.spill}                           ;# pid 1 is alive; made OLD below: a running process's folder is never swept, however old
set ns [mkitsql::pidNs]
mkdirWith mkitsql-$u-999991-$ns-0123456789abcdef {000001.spill}                 ;# dead process, our namespace
mkdirWith mkitsql-$u-999990-4242424242-0123456789abcdef {000001.spill}          ;# another PID namespace: its pid means nothing here
mkdirWith mkitsql-$u-999998-0123456789abcdef {000001.spill notmine.txt}         ;# contains something that is not a spill file
mkdirWith mkitsql-$u-999997-0123456789abcdef {}                                 ;# empty, dead
mkdirWith mkitsql-$u-999996-xyz {000001.spill}                                  ;# does not match the name pattern
set fh [open $area/mkitsql_999995_7.spill w] ; close $fh                         ;# a file of an older version
set fh [open $area/mkitsql_1_7.spill w] ; close $fh                              ;# older-version name, pid alive, fresh
set fh [open $area/unrelated.txt w] ; close $fh
file mkdir $area/elsewhere_dir ; set fh [open $area/elsewhere_dir/000001.spill w] ; close $fh
file link -symbolic $area/mkitsql-$u-999994-0123456789abcdef $area/elsewhere_dir
set old [expr {[clock seconds] - 3 * 86400}]
file mtime $area/mkitsql-$u-1-1111111111111111 $old
file mtime $area/mkitsql-$u-1-0123456789abcdef [clock seconds]
check pid_999999_dead [mkitsql::pidAlive 999999] 0
check pid_1_alive [mkitsql::pidAlive 1] 1
check pid_self_alive [mkitsql::pidAlive [pid]] 1
set n [mkitsql::cleanTemp $area]
set left [lmap_ [entries] {p {file tail $p}}]
check swept_count $n 4
check dead_folder_removed [expr {[lsearch $left mkitsql-$u-999999-0123456789abcdef] < 0}] 1
check live_fresh_folder_kept [expr {[lsearch $left mkitsql-$u-1-0123456789abcdef] >= 0}] 1
check old_folder_of_live_process_kept [expr {[lsearch $left mkitsql-$u-1-1111111111111111] >= 0}] 1
check dead_folder_with_namespace_removed [expr {[lsearch $left mkitsql-$u-999991-$ns-0123456789abcdef] < 0}] 1
check foreign_namespace_kept [expr {[lsearch $left mkitsql-$u-999990-4242424242-0123456789abcdef] >= 0}] 1
check folder_with_foreign_file_kept [expr {[lsearch $left mkitsql-$u-999998-0123456789abcdef] >= 0}] 1
check empty_dead_folder_removed [expr {[lsearch $left mkitsql-$u-999997-0123456789abcdef] < 0}] 1
check odd_name_kept [expr {[lsearch $left mkitsql-$u-999996-xyz] >= 0}] 1
check legacy_dead_file_removed [expr {[lsearch $left mkitsql_999995_7.spill] < 0}] 1
check legacy_live_file_kept [expr {[lsearch $left mkitsql_1_7.spill] >= 0}] 1
check unrelated_kept [file exists $area/unrelated.txt] 1
check link_never_followed_or_removed [list [file type $area/mkitsql-$u-999994-0123456789abcdef] [file exists $area/elsewhere_dir/000001.spill]] {link 1}
check sweep_idempotent [mkitsql::cleanTemp $area] 0

# ---- the sweep runs by itself on the first spill of a process -----------------------------------------------------------
mkdirWith mkitsql-$u-999993-0123456789abcdef {000001.spill}
set mkitsql::tempCleaned 0
q "SELECT s FROM t ORDER BY s"
check auto_sweep [file exists $area/mkitsql-$u-999993-0123456789abcdef] 0
check auto_sweep_second_time_skipped [mkitsql::cleanTemp] 0

# ---- unusable temp folders are reported clearly ------------------------------------------------------------------------------
set mkitsql::tempDir $area/no/such
check bad_temp_msg [string match "*does not exist or is not writable*" [expr {[catch {q "SELECT s FROM t ORDER BY s"} m] ? $m : ""}]] 1
set mkitsql::tempDir $area
file attributes $area -permissions u=rx,go=
if {[file writable $area]} { puts "(running as root: read-only folder check skipped)" } else {
    check readonly_temp_msg [string match "*writable*" [expr {[catch {q "SELECT s FROM t ORDER BY s"} m] ? $m : ""}]] 1
}
file attributes $area -permissions u=rwx,go=
check works_again [llength [dict get [q "SELECT s FROM t ORDER BY s"] rows]] 300

mkitsql::db::closeFile $db
file delete -force $area
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
