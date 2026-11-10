# The disk flush uses the native mksync library when there is one and falls back to a program when there is not:
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/native_flush.tcl
# mksync is feature-detected, never required: ::mksync::flush already defined, or `package require mksync` working.  Stand-ins for the
# library (a command that records its calls, a package of one) test every branch on any machine; if a real mksync is installed
# (TCLLIBPATH, auto_path) it is exercised too, and says so.
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
source $here/mkutil.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 200]\n  want: [string range $want 0 200]"} }
set mkitsql::db::durable 1
set area [tmp mkitsql_native_[pid]] ; file delete -force $area ; file mkdir $area
set f $area/n.mk ; set a $area/a.txt ; set b $area/sub-b.txt
set windows [expr {$::tcl_platform(platform) eq "windows"}]
set fallback [expr {$windows ? "*" : "sync"}]

# a program started for the flush is a call of `exec sync`; counted by wrapping exec
set ::execSync 0
rename ::exec ::execReal
proc ::exec {args} { if {[lindex $args 0] eq "sync"} { incr ::execSync } ; uplevel 1 [list ::execReal {*}$args] }
proc fresh {} {
    set ::mkitsql::db::native -1
    set ::execSync 0 ; set ::flushed {}
    foreach x [glob -nocomplain $::f $::f.*] { file delete -force $x }
}
proc fakeCommand {{body {return [llength $args]}}} {
    namespace eval ::mksync {}
    proc ::mksync::flush {args} "lappend ::flushed \$args ; $body"
    proc ::mksync::method {} { return fake }
}
proc removeFake {} { catch {namespace delete ::mksync} ; package forget mksync }
# a package that `package require mksync` finds
proc fakePackage {script} { package forget mksync ; package ifneeded mksync 1.0 $script }
# one commit of a few rows; the rows are read back by a second open
proc commitRows {} {
    set db [mkitsql::db::openFile $::f -create]
    mkitsql::db::createView $db t {{k I {}}}
    for {set i 0} {$i < 20} {incr i} { mkitsql::db::appendRow $db.t k $i }
    mkitsql::db::commit $db
    mkitsql::db::closeFile $db
    set db [mkitsql::db::openFile $::f -readonly]
    set n [mkitsql::db::size $db.t]
    mkitsql::db::closeFile $db
    return $n
}
# nothing can be found under the name mksync (whatever is installed here)
set savedUnknown [package unknown]
proc blockPackage {} { package unknown {apply {{name args} { if {$name eq "mksync"} { error "can't find package mksync" } }}} }
proc unblockPackage {} { package unknown $::savedUnknown }

# 0. a real mksync, if this machine has one (first: the stand-ins below replace the package)
fresh
if {[catch {package require mksync}]} {
    puts "  (no mksync library on this machine: the real-library checks are skipped)"
} else {
    puts "  real mksync [package provide mksync], method [mksync::method]"
    set ::mkitsql::db::native -1
    check "real mksync: native" [mkitsql::db::nativeFlush] 1
    set h [open $a w] ; puts $h x ; close $h
    check "real mksync: syncDisk reports success" [mkitsql::db::syncDisk $a] 1
    foreach x [glob -nocomplain $f $f.*] { file delete -force $x }
    check "real mksync: a commit works" [commitRows] 20
    check "real mksync: no program was started" $::execSync 0
}
removeFake

# 1. no library at all: the program is used, and the commit works
removeFake ; blockPackage ; fresh
check "no mksync: not native" [mkitsql::db::nativeFlush] 0
check "no mksync: the method is the fallback" [string match $fallback [mkitsql::db::flushMethod]] 1
if {!$windows} { check "no mksync: syncDisk reports the flush" [mkitsql::db::syncDisk $f] 1 }
fresh
check "no mksync: a commit works" [commitRows] 20
if {!$windows} { check "no mksync: it flushed through `sync`" [expr {$::execSync > 0}] 1 }
unblockPackage

# 2. a command that is already there is used, and no program is started
removeFake ; fakeCommand ; fresh
check "fake command: native" [mkitsql::db::nativeFlush] 1
check "fake command: the method names it" [mkitsql::db::flushMethod] "native (fake)"
check "fake command: syncDisk reports success" [mkitsql::db::syncDisk $b $a $a] 1
check "fake command: asked once, for the files and their folder, each once, sorted" $::flushed [list [lsort -unique [list $a $b $area]]]
fresh
check "fake command: a commit works" [commitRows] 20
check "fake command: the file, its record and the folder were flushed" [expr {[lsearch -exact [concat {*}$::flushed] $f] >= 0 && [lsearch -exact [concat {*}$::flushed] $f.commit] >= 0 && [lsearch -exact [concat {*}$::flushed] $area] >= 0}] 1
check "fake command: no program was started" $::execSync 0

# 3. the same command, switched off by MKIT_NATIVE=0
set ::env(MKIT_NATIVE) 0 ; fresh
check "MKIT_NATIVE=0: not native although the command is there" [mkitsql::db::nativeFlush] 0
check "MKIT_NATIVE=0: a commit works through the program" [commitRows] 20
check "MKIT_NATIVE=0: the command was not called" $::flushed {}
if {!$windows} { check "MKIT_NATIVE=0: `sync` was used" [expr {$::execSync > 0}] 1 }
unset ::env(MKIT_NATIVE)

# 4. found as a package on auto_path
removeFake ; fakePackage {namespace eval ::mksync {} ; proc ::mksync::flush {args} { lappend ::flushed $args ; return [llength $args] } ; proc ::mksync::method {} { return pkg } ; package provide mksync 1.0}
fresh
check "package: native" [mkitsql::db::nativeFlush] 1
check "package: the method names it" [mkitsql::db::flushMethod] "native (pkg)"
check "package: a commit works through it" [commitRows] 20
check "package: it was called and no program started" [list [expr {[llength $::flushed] > 0}] $::execSync] {1 0}

# 5. a package that loads but has no flush command: the fallback
removeFake ; fakePackage {namespace eval ::mksync {} ; package provide mksync 1.0}
fresh
check "package without flush: not native" [mkitsql::db::nativeFlush] 0
check "package without flush: a commit works" [commitRows] 20

# 6. a package that fails to load: the fallback, no error
removeFake ; fakePackage {error "cannot load the library"}
fresh
check "broken package: not native" [mkitsql::db::nativeFlush] 0
check "broken package: a commit works" [commitRows] 20

# 7. the native call refuses (the system or the disk reported a failure): reported as not flushed, never an error, no second try by program
removeFake ; fakeCommand {return -code error -errorcode {MKSYNC FLUSH x} "could not flush"} ; fresh
check "refusal: syncDisk reports failure" [mkitsql::db::syncDisk $f] 0
check "refusal: a commit still completes" [commitRows] 20
check "refusal: no program was started instead" $::execSync 0

# 8. durable 0: nothing is flushed at all
removeFake ; fakeCommand ; fresh ; set mkitsql::db::durable 0
check "durable 0: syncDisk does nothing" [mkitsql::db::syncDisk $f] 0
check "durable 0: the method" [mkitsql::db::flushMethod] off
check "durable 0: the command was not called" $::flushed {}
set mkitsql::db::durable 1

rename ::exec {} ; rename ::execReal ::exec
file delete -force $area
puts "native flush: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
