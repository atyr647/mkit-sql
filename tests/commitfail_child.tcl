# child of commitfail.tcl: runs under a file-size limit (prlimit --fsize) so that a commit eventually fails
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv path
set db [mkitsql::db::openFile $path -create]
if {[catch {mkitsql::db::createView $db t {{k I {}} {s S {}}}}]} {}
set n [mkitsql::db::size $db.t]
set committed $n
set code NONE ; set msg ""
for {set round 0} {$round < 200} {incr round} {
    for {set i 0} {$i < 100} {incr i} { mkitsql::db::appendRow $db.t {k s} [list [incr n] [string repeat x 200]] }
    if {[catch {mkitsql::db::commit $db} err opts]} { set code [lrange [dict get $opts -errorcode] 0 1] ; set msg $err ; break }
    set committed $n
}
set after [catch {mkitsql::db::size $db.t} rows]
puts "RESULT code=[list $code] committed=$committed rows_after=$rows pending=[mkitsql::db::dirty $db] recordLeft=[file exists $path.commit]"
catch {mkitsql::db::closeFile $db}
