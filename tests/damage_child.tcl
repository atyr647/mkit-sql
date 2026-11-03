# Child for tests/damage.tcl: commit 5000-row batches through mkit-sql until killed.
#   tclsh damage_child.tcl <dbfile>
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set f [lindex $argv 0]
fconfigure stdout -buffering line
set tag [mkitsql::db::openFile $f -create]
if {![mkitsql::db::hasView $tag t]} { mkitsql::run "CREATE TABLE t (id INT, name TEXT, v DOUBLE PRECISION, kids TABLE (k TEXT))" $tag ; mkitsql::run COMMIT $tag }
set k [lindex [lindex [dict get [mkitsql::run "SELECT COUNT(*) FROM t" $tag] rows] 0] 0]
set k [expr {$k / 5000}]
while 1 {
    set rows {}
    for {set i 0} {$i < 5000} {incr i} { set n [expr {$k * 5000 + $i}] ; lappend rows "($n, 'row $n padding padding padding', [expr {$n / 7.0}])" }
    mkitsql::run "INSERT INTO t (id, name, v) VALUES [join $rows ,]" $tag
    mkitsql::run COMMIT $tag
    incr k
    puts "committed $k"
}
