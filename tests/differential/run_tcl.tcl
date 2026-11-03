# Runs a script file through mkit-sql and writes one JSON line per query.
#   tclsh run_tcl.tcl script.txt out.jsonl
# script.txt: one statement per line, prefixed "S " (setup, no output) or "Q " (query, output).
set here [file dirname [file normalize [info script]]]
set root [file dirname [file dirname $here]]
source $root/tests/mk4load.tcl
source $root/tests/vendor/store.tcl
source $root/mkitsql/mkitsql.tcl
lassign $argv script out
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_diff_[pid].mk
file delete $tmp
set db [store::openFile $tmp -create]
set mkitsql::nullText "NULL"

proc jstr {s} {
    set s [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $s]
    regsub -all {[\u0000-\u001f]} $s {} s
    return "\"$s\""
}
proc jval {v} { if {$v eq "NULL"} { return null } ; return [jstr $v] }

set in [open $script r] ; fconfigure $in -encoding utf-8
set o [open $out w] ; fconfigure $o -encoding utf-8
while {[gets $in line] >= 0} {
    if {$line eq ""} continue
    set kind [string index $line 0] ; set sql [string range $line 2 end]
    if {[catch {mkitsql::run $sql $db} r]} {
        if {$kind eq "Q"} { puts $o "\{\"ok\":false,\"err\":[jstr $r]\}" } else { puts stderr "SETUP FAILED: $sql\n  $r" }
        continue
    }
    if {$kind ne "Q"} continue
    if {[dict get $r kind] ne "rowset"} { puts $o "\{\"ok\":true,\"rows\":[]\}" ; continue }
    set rows {}
    foreach row [dict get $r rows] {
        set cells {}
        foreach v $row { lappend cells [jval $v] }
        lappend rows "\[[join $cells ,]\]"
    }
    puts $o "\{\"ok\":true,\"rows\":\[[join $rows ,]\]\}"
}
close $in ; close $o
store::closeFile $db ; file delete $tmp
