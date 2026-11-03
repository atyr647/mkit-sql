# col LIKE 'abc%' / '%abc%' is handed to Metakit's -glob.  It may only ever NARROW the scan: results with the push on and off must be identical for
# every pattern and every text (metacharacters of glob, unicode, newlines, empty strings), and the shortcut must really be taken.   tclsh tests/likepush.tcl [rounds]
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set rounds [expr {$argc > 0 ? [lindex $argv 0] : 300}]
expr {srand(31)}
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_lp_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 200]\n   want: [string range $want 0 200]" } }
proc q {sql} { mkitsql::run $sql $::db }
q "CREATE TABLE w (id INT, s TEXT)"
set alpha [list a b c A B x * ? \[ \] \\ % _ " " "\n" . - [format %c 233] [format %c 26085] "'" "\""]
set rows {} ; set id 0
for {set i 0} {$i < 900} {incr i} {
    set t "" ; for {set j 0} {$j < int(rand() * 7)} {incr j} { append t [lindex $alpha [expr {int(rand() * [llength $alpha])}]] }
    lappend rows [list [incr id] $t]
}
mkitsql::insertRows $db w {} $rows ; q COMMIT
proc lit {s} { return "'[string map {' ''} $s]'" }
set scans0 $::mkitsql::pushScans
set pushed 0
for {set r 0} {$r < $rounds} {incr r} {
    set pat "" ; for {set j 0} {$j < 1 + int(rand() * 5)} {incr j} { append pat [lindex [concat $alpha $alpha {% %}] [expr {int(rand() * ([llength $alpha] * 2 + 2))}]] }
    set esc [expr {rand() < 0.15 ? " ESCAPE '\\'" : ""}]
    foreach neg {"" "NOT "} {
        set sql "SELECT id FROM w WHERE s ${neg}LIKE [lit $pat]$esc ORDER BY id"
        set ::mkitsql::pushdown 0 ; set off [dict get [q $sql] rows]
        set ::mkitsql::pushdown 1 ; set b $::mkitsql::pushScans ; set on [dict get [q $sql] rows]
        if {$::mkitsql::pushScans > $b} { incr pushed }
        check "LIKE [lit $pat]$esc" $on $off
    }
}
check "the shortcut was taken for many patterns" [expr {$pushed > $rounds / 5}] 1
# patterns that must be pushed, and the plan says so
set ::mkitsql::pushdown 1
set b $::mkitsql::pushScans ; q "SELECT id FROM w WHERE s LIKE 'ab%'" ; check "prefix pattern pushed" [expr {$::mkitsql::pushScans > $b}] 1
set b $::mkitsql::pushScans ; q "SELECT id FROM w WHERE s LIKE '%ab%'" ; check "contains pattern pushed" [expr {$::mkitsql::pushScans > $b}] 1
foreach no {"s LIKE 'a_c'" "s ILIKE 'ab%'" "s NOT LIKE 'ab%'" "s LIKE '%'" "s LIKE ''" "s SIMILAR TO 'ab%'" "s LIKE 'a#_b' ESCAPE '#'"} {
    set b $::mkitsql::pushScans ; q "SELECT id FROM w WHERE $no" ; check "not pushed: $no" $::mkitsql::pushScans $b
}
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "LIKE push-down: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
