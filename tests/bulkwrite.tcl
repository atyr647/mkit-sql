# Large DELETE / UPDATE rebuild the table instead of changing it row by row (Metakit is quadratic for
# scattered deletes and string updates).  The two strategies must give identical files.
#   tclsh tests/bulkwrite.tcl [rounds] [seed]
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set rounds [expr {$argc > 0 ? [lindex $argv 0] : 40}]
expr {srand([expr {$argc > 1 ? [lindex $argv 1] : 1}])}
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
# every row of a view, subviews included
proc dump {path layout} {
    set props {} ; set subs {}
    foreach c $layout { if {[lindex $c 1] eq "V"} { lappend subs $c } else { lappend props [lindex $c 0] } }
    set out {} ; set n [mkitsql::db::size $path] ; set i 0
    foreach r [mkitsql::db::rows $path $props 0 $n] {
        set row [list $r]
        foreach sc $subs { lappend row [dump $path!$i.[lindex $sc 0] [lindex $sc 2]] }
        lappend out $row ; incr i
    }
    return $out
}
set layout {{id I {}} {grp I {}} {name S {}} {val D {}} {tag B {}} {kids V {{k S {}} {w I {}}}}}
proc build {file bulkMin} {
    global layout
    file delete $file
    set db [mkitsql::db::openFile $file -create]
    mkitsql::db::createView $db t $layout
    for {set i 0} {$i < 300} {incr i} {
        set j [mkitsql::db::appendRow $db.t {id grp name val tag} [list $i [expr {$i % 7}] "name$i" [expr {$i / 4.0}] "b$i"]]
        for {set k 0} {$k < $i % 3} {incr k} { mkitsql::db::appendRow $db.t!$j.kids {k w} [list "kid$i.$k" $k] }
    }
    mkitsql::db::commit $db
    return $db
}
set A [build $tmp/mkitsql_bw_a_[pid].mk 1000000000]
set B [build $tmp/mkitsql_bw_b_[pid].mk 1]
proc runBoth {sql} {
    global A B
    set res {}
    foreach {db bm} [list $A 1000000000 $B 1] {
        set mkitsql::bulkMin $bm
        if {[catch {mkitsql::run $sql $db} r]} { lappend res "ERROR $r" } else { lappend res [dict get $r affected] }
    }
    return $res
}
set stmts {
    {DELETE FROM t WHERE id % 2 = 1}
    {DELETE FROM t WHERE grp = 3}
    {DELETE FROM t WHERE id > 250}
    {DELETE FROM t WHERE id BETWEEN 40 AND 60}
    {DELETE FROM t WHERE id % 5 = 0}
    {DELETE FROM t WHERE 1 = 0}
    {UPDATE t SET name = name || 'xx' WHERE id % 3 = 0}
    {UPDATE t SET name = UPPER(name), val = val * 2}
    {UPDATE t SET name = SUBSTR(name, 2) WHERE grp < 4}
    {UPDATE t SET tag = tag || tag WHERE id % 2 = 0}
    {UPDATE t SET grp = grp + 1}
    {UPDATE t SET name = 'z' WHERE id < 0}
    {UPDATE t SET name = name || '!', grp = 9 WHERE id % 11 = 0}
    {INSERT INTO t (id, grp, name, val, tag) SELECT id + 1000, grp, name, val, tag FROM t WHERE id % 4 = 0}
    {MERGE INTO t USING (SELECT 5 AS i) s ON t.id = s.i WHEN MATCHED THEN DELETE}
}
for {set r 0} {$r < $rounds} {incr r} {
    set sql [lindex $stmts [expr {int(rand() * [llength $stmts])}]]
    set res [runBoth $sql]
    check "round $r: [string range $sql 0 50] (count)" [lindex $res 0] [lindex $res 1]
    check "round $r: contents" [dump $B.t $layout] [dump $A.t $layout]
    set sizes($r) [mkitsql::db::size $B.t]
    # keep the table from emptying: top it up (identically in both) from time to time
    if {$sizes($r) < 120} {
        foreach {db bm} [list $A 1000000000 $B 1] {
            set mkitsql::bulkMin $bm
            for {set i 0} {$i < 200} {incr i} {
                set j [mkitsql::db::appendRow $db.t {id grp name val tag} [list [expr {5000 + $r * 1000 + $i}] [expr {$i % 7}] "more$i" [expr {$i / 8.0}] "c$i"]]
                for {set k 0} {$k < $i % 3} {incr k} { mkitsql::db::appendRow $db.t!$j.kids {k w} [list "kk$i.$k" $k] }
            }
        }
    }
    if {rand() < 0.15} { runBoth "ROLLBACK" ; check "round $r: after rollback" [dump $B.t $layout] [dump $A.t $layout] }
}
set mn 1000000 ; set mx 0
foreach {k v} [array get sizes] { if {$v < $mn} { set mn $v } ; if {$v > $mx} { set mx $v } }
puts "(table sizes during the run: $mn .. $mx rows)"
check "scratch view gone" [lsearch -glob [mkitsql::db::views $B] __mkitsql_tmp*] -1
mkitsql::db::closeFile $A ; mkitsql::db::closeFile $B
file delete $tmp/mkitsql_bw_a_[pid].mk $tmp/mkitsql_bw_b_[pid].mk
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
