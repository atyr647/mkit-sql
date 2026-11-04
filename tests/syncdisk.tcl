# Forcing a file to disk works on this system: syncDisk must report that it asked the system to flush (on Windows this starts PowerShell).
#   tclkit tests/syncdisk.tcl
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_sync_[pid].txt
set h [open $f w] ; puts $h "hello" ; close $h
set pass 0 ; set fail 0
proc check {name got want} { global pass fail ; if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" } }
set mkitsql::db::durable 1
set t0 [clock milliseconds]
check "syncDisk on a file reports success" [mkitsql::db::syncDisk $f] 1
puts "  (took [expr {[clock milliseconds] - $t0}] ms on $::tcl_platform(os))"
check "again" [mkitsql::db::syncDisk $f] 1
check "a missing file is not an error" [catch {mkitsql::db::syncDisk $tmp/does-not-exist-[pid]}] 0
if {$::tcl_platform(platform) eq "windows"} {
    # PowerShell started straight from a GUI program does nothing yet exits 0: only a file the script writes proves it ran
    set marker $tmp/mkitsql_ps_ran_[pid].txt ; file delete $marker
    lassign [mkitsql::db::psRun "Set-Content -LiteralPath '[string map {' ''} [file nativename $marker]]' -Value ran"] ran ok out
    check "PowerShell started" $ran 1
    check "PowerShell really executed the script" [file exists $marker] 1
    file delete $marker
    lassign [mkitsql::db::psRun "exit 3"] ran ok out
    check "a failing script is a failure" $ok 0
}
set mkitsql::db::durable 0
check "durable 0 does nothing" [mkitsql::db::syncDisk $f] 0
file delete $f
puts "syncDisk: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
