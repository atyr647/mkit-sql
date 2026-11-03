# Query a Metakit file that was NOT made by these tests.  A tclkit's boot database is one: a virtual
# file system with nested tables (subviews) and binary columns.
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/realworld.tcl tclkit/tclkit-8.5.17
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
if {$argc < 1} { puts "usage: realworld.tcl <a tclkit or other Metakit file>" ; exit 2 }
set copy [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_rw_[pid].kit
file copy -force [lindex $argv 0] $copy
set db [store::openFile $copy -readonly]
set pass 0 ; set fail 0
proc t {name sql {check {}}} {
    global db pass fail
    set t0 [clock milliseconds]
    if {[catch {mkitsql::run $sql $db} r]} { incr fail ; puts "FAIL $name: $r\n   $sql" ; return }
    set rows [expr {[dict exists $r rows] ? [dict get $r rows] : {}}]
    if {$check ne "" && ![expr $check]} { incr fail ; puts "FAIL $name: check failed ([lrange $rows 0 2])" ; return }
    incr pass
    puts [format "ok %5d ms %7d rows  %s" [expr {[clock milliseconds] - $t0}] [llength $rows] $name]
}
puts "views: [store::views $db]  (Tcl [info patchlevel])"
t tables   "SHOW TABLES" {[llength $rows] >= 1}
t describe "DESCRIBE dirs" {[llength $rows] >= 3}
t info_schema "SELECT table_name, row_count FROM information_schema.tables" {[llength $rows] >= 1}
t dirs     "SELECT COUNT(*) FROM dirs" {[lindex $rows 0 0] > 10}
t paths    "SELECT name, files FROM dirs ORDER BY name LIMIT 20"
t files_unnest "SELECT d.name, f.name FROM dirs d JOIN d.files f ON 1 = 1 ORDER BY d.name, f.name LIMIT 50" {[llength $rows] == 50}
t file_sizes "SELECT COUNT(*), SUM(f.size), MAX(f.size), AVG(f.size) FROM dirs d JOIN d.files f ON 1 = 1" {[lindex $rows 0 0] > 100}
t blob_len "SELECT f.name, LENGTH(f.contents) FROM dirs d JOIN d.files f ON 1 = 1 WHERE f.size > 0 ORDER BY f.size DESC LIMIT 5"
t group    "SELECT d.name, COUNT(*) AS n, SUM(f.size) FROM dirs d JOIN d.files f ON 1 = 1 GROUP BY d.name ORDER BY n DESC LIMIT 10"
t window   "SELECT d.name, f.name, f.size, RANK() OVER (PARTITION BY d.name ORDER BY f.size DESC) FROM dirs d JOIN d.files f ON 1 = 1 LIMIT 20"
t like     "SELECT d.name, f.name FROM dirs d JOIN d.files f ON 1 = 1 WHERE f.name LIKE '%.tcl' LIMIT 10" {[llength $rows] > 0}
t subq     "SELECT name FROM dirs d WHERE (SELECT COUNT(*) FROM d.files) > 5 ORDER BY name"
t byrow    "SELECT name, size FROM dirs\[1\].files LIMIT 5"
store::closeFile $db ; file delete $copy
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
