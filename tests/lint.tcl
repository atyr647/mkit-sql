# Static checks:  tclsh tests/lint.tcl
#  1. no proc may share its name with a Tcl command (inside its own namespace the proc would
#     silently replace the command) - this also checks procs created dynamically
#  2. every source file is pure ASCII (Tcl's `source` encoding is platform dependent)
#  3. no Tcl 8.6-only commands, so classic 8.5 tclkits keep working
#  4. INVENTORY OF CODE BOUNDARIES: every place in mkitsql/ that can turn a string into code or reach
#     outside the process (eval, uplevel, subst, dynamically named procs, open, exec, ...) is listed
#     below with the exact number of occurrences.  Adding one - or removing one - fails the lint until
#     the table (and the review of that boundary) is updated on purpose.
set root [file dirname [file dirname [file normalize [info script]]]]
set builtin {after append apply array binary break catch chan clock close concat continue dict encoding eof
    error eval exec exit expr file fileevent flush for foreach format gets glob global if incr info interp
    join lappend lassign lindex linsert list llength lrange lrepeat lreplace lreverse lsearch lset lsort
    namespace open package pid proc puts pwd read regexp regsub rename return scan seek set socket source
    split string subst switch tell time trace unset update uplevel upvar variable vwait while}
set only86 {lmap try finally throw tailcall lseq}
# commands newer than MK Studio's runtimes (tclkit 8.6.3, and 8.5.17 for old kits) - none may be used
set only86pairs {{string cat} {string reverse} {dict getdef} {dict getwithdefault} {binary encode} {binary decode}
    {lsort -stride} {chan configure} {info cmdcount} {string is entier} {string insert} {dict map}
    {tcl::prefix} {tcl::unsupported} {info coroutine} {file tempdir} {file tempfile} {interp cancel}
    {lpop} {lremove}}
set fails 0
foreach f [lsort [concat [glob -directory $root/mkitsql *.tcl] [glob -directory $root/tests *.tcl]]] {
    set in [open $f r] ; fconfigure $in -translation binary ; set bin [read $in] ; close $in
    if {[regexp {[\x80-\xff]} $bin]} { puts "NON-ASCII in [file tail $f]" ; incr fails }
    if {[file tail $f] eq "lint.tcl"} continue
    set src $bin
    set n 0
    foreach line [split $src \n] {
        incr n
        if {[string match "\\#*" [string trimleft $line]]} continue
        foreach w $only86 {
            if {[regexp "(^|\[\\\[;\{\] *)$w " $line]} { puts "8.6-only '$w' at [file tail $f]:$n" ; incr fails }
        }
        foreach w $only86pairs {
            if {[string first "$w" $line] >= 0} { puts "8.6-only '$w' at [file tail $f]:$n" ; incr fails }
        }
    }
}
# ---- 4. inventory of string -> code boundaries ----------------------------------------------------
# {file  command-pattern  count  why it is safe}
set boundaries [list \
    [list exec.tcl    {(^|\[)eval }          1 "runs a command prefix that the executor itself assembled (no SQL text)"] \
    [list bind.tcl    {(^|[\[ \{])uplevel }  2 "withScopes / lmap2 run a script literal written in this file"] \
    [list expr.tcl    {^\s*proc [^ \{]*\$}   4 "defstrict (names from this file) and the three cx::pN procs, verified by verify.tcl"] \
    [list db.tcl      {catch \{open }          1 "the lock file, created exclusively (O_EXCL) - the protocol of MK Studio's docs/CONCURRENCY.md"] \
    [list db.tcl      {(^|\[)open }            13 "the checksum file (write, the whole-file read for the crc), the lock file (create, bounded read, the bounded re-read after writing it), its takeover guard (O_EXCL), /proc/<pid>/stat and /proc/stat; the commit record (one helper writes it before a commit and rewrites it after; one read) and the database file (rewritten header / cut back to undo an interrupted commit)"] \
    [list dbcommon.tcl {(^|\[)open }           8 "reads the checksum file (a plain small file only), the 8-byte header and the 16- or 24-byte footer of a database file and the commit record, to decide whether a repair of an interrupted commit is safe; and, in the wide-format probe, creates (exclusively, mode 0600) and reads two tiny files in the temporary folder"] \
    [list db.tcl      {\{exec }                2 "`sync` (coreutils) and, on Windows, PowerShell FlushFileBuffers force the database file and its commit record to disk around a commit; fixed commands, file names go in through the environment"] \
    [list db.tcl      {catch \{exec }          2 "the same two flush calls"] \
    [list db.tcl      {(^|\[)after }           1 "waits 40 ms for another process's takeover guard, as the lock protocol says (no event loop is entered)"] \
    [list dbcheck.tcl {(^|\[)open }            2 "reads the first and last bytes of a database file to validate its frame"] \
    [list spill.tcl   {(^|\[)open }            2 "reads /dev/urandom for the private folder's random name, and /proc/<pid>/stat"] \
    [list dbcheck.tcl {catch \{open }          1 "the verifier helper process (a pipe to verify_child.tcl)"] \
    [list dbcheck.tcl {\{exec }                1 "kills the verifier helper if it hangs (a pid it started itself)"] \
    [list spill.tcl   {\{exec }                2 "process-liveness probe (see above)"] \
    [list dbcheck.tcl {(^|\[)after }           1 "sleeps 10 ms while polling the verifier helper (no event loop is entered)"] \
    [list spill.tcl   {catch \{open }          2 "the spill file path is built by spillNewPath from the temp dir + a counter"] \
    [list mkitsql.tcl {(^|[\[ \{])source -}  5 "loads this package's own files (core, shared storage code, and one of the two storage layers)"] \
    [list spill.tcl   {catch \{exec }          2 "process-liveness probe (kill -0 / tasklist) with a pid already checked to be a positive integer"] \
    [list stmt.tcl    {(^|\[)rename }        1 "deletes the generated cx::pN procs"] \
    [list pkgIndex.tcl {(^|[\[ \{])source -}  1 "package index: loads mkitsql.tcl"]]
# any other dynamic-code or process command anywhere in mkitsql/ is a lint failure.  int( is on the list too: int() keeps only a machine word,
# which is 32 bits on 64-bit Windows Tcl 8 (dates and BIGINT went wrong there) - use entier()
set forbidden {{(^|\[)subst } {(^|\[)interp } {(^|\[)exec } {(^|\[)trace } {(^|\[)socket }
    {(^|\[)fileevent } {info body} {regsub [^#\n]*-command} {(^|\[)uplevel #0} {(^|\[)namespace inscope}
    {(^|\[)interp alias} {(^|\[)load } {(^|\[)vwait }
    {(^|[^A-Za-z_:])int\(}
    {(EXCL\}|-permissions|&) 0[0-7]{2,}}}   ;# a leading-zero file mode / mask: octal in Tcl 8, decimal in Tcl 9 - write modes in decimal
foreach f [glob -directory $root/mkitsql *.tcl] {
    set in [open $f r] ; set code [read $in] ; close $in
    set lines {}
    foreach line [split $code \n] {
        set t [string trim $line]
        if {[string index $t 0] eq "#"} continue
        lappend lines $t
    }
    set tail [file tail $f]
    foreach pat $forbidden {
        foreach line $lines {
            if {[regexp -- $pat $line]} { puts "FORBIDDEN boundary '$pat' in $tail: $line" ; incr fails }
        }
    }
    # every inventoried pattern, in every file: the listed count in its own file, zero everywhere else
    set pats {}
    foreach b $boundaries { lappend pats [lindex $b 1] }
    foreach pat [lsort -unique $pats] {
        set want 0 ; set why "not allowed in this file"
        foreach b $boundaries { if {[lindex $b 0] eq $tail && [lindex $b 1] eq $pat} { set want [lindex $b 2] ; set why [lindex $b 3] } }
        set got 0
        foreach line $lines { if {[regexp -- $pat $line]} { incr got } }
        if {$got != $want} { puts "BOUNDARY CHANGED in $tail: '$pat' found $got times, inventory says $want ($why)" ; incr fails }
    }
}
foreach b $boundaries {
    lassign $b file pat want why
    if {$want == 0} continue
    set seen 0
    foreach f [glob -directory $root/mkitsql *.tcl] { if {[file tail $f] eq $file} { set seen 1 } }
    if {!$seen} { puts "inventory names a missing file: $file" ; incr fails }
}
# dynamic shadow check: load the engine and look at every namespace it defines procs in
set ::env(MKIT_LINT) 1
source $root/tests/vendor/mock_mk4tcl.tcl
source $root/tests/vendor/store.tcl
source $root/mkitsql/mkitsql.tcl
proc scan_ns {ns} {
    global builtin fails
    foreach p [info procs ${ns}::*] {
        set tail [namespace tail $p]
        if {[lsearch -exact $builtin $tail] >= 0} { puts "SHADOWS Tcl command: $p" ; incr fails }
    }
    foreach child [namespace children $ns] { scan_ns $child }
}
scan_ns ::mkitsql
puts [expr {$fails ? "$fails lint problem(s)" : "lint clean"}]
exit [expr {$fails ? 1 : 0}]
