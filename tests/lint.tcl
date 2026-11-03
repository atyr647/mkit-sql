# Static checks:  tclsh tests/lint.tcl
#  1. no proc may share its name with a Tcl command (inside its own namespace the proc would
#     silently replace the command) - this also checks procs created dynamically
#  2. every source file is pure ASCII (Tcl's `source` encoding is platform dependent)
#  3. no Tcl 8.6-only commands, so classic 8.5 tclkits keep working
set root [file dirname [file dirname [file normalize [info script]]]]
set builtin {after append apply array binary break catch chan clock close concat continue dict encoding eof
    error eval exec exit expr file fileevent flush for foreach format gets glob global if incr info interp
    join lappend lassign lindex linsert list llength lrange lrepeat lreplace lreverse lsearch lset lsort
    namespace open package pid proc puts pwd read regexp regsub rename return scan seek set socket source
    split string subst switch tell time trace unset update uplevel upvar variable vwait while}
set only86 {lmap try finally throw tailcall lseq}
set only86pairs {{string cat} {string reverse} {dict getdef} {dict getwithdefault} {binary encode} {binary decode}
    {lsort -stride} {chan configure} {info cmdcount} {string is entier}}
set fails 0
foreach f [lsort [concat [glob -directory $root/mkitsql *.tcl] [glob -directory $root/tests *.tcl]]] {
    set in [open $f r] ; fconfigure $in -encoding binary ; set bin [read $in] ; close $in
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
