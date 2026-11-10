# child of metakit_lock.tcl.   args: mode file ?ready-file?
#   hold        mkit-sql opens the file for writing and keeps it until <ready>.go appears (or 30 s)
#   die         mkit-sql opens the file for writing, says so, and kills itself with SIGKILL
#   open        mkit-sql opens it (the lock-file protocol and Metakit's lock): prints what happened
#   open-bare   the same from a program that does not follow the lock-file protocol (only Metakit's own lock is left)
#   raw-open    plain Mk4tcl, default options
#   raw-commit  plain Mk4tcl, -nolock, adds a row 777 and commits
set here [file dirname [file normalize [info script]]]
set ::env(MKIT_BACKEND) standalone
source $here/mk4load.tcl
source $here/loadengine.tcl
lassign $argv mode f ready
proc say {args} { puts $args ; flush stdout }
switch -- $mode {
    hold - die {
        set db [mkitsql::db::openFile $f]
        set h [open $ready w] ; puts $h $db ; close $h
        if {$mode eq "die"} { exec kill -9 [pid] ; after 5000 }
        for {set i 0} {$i < 300 && ![file exists $ready.go]} {incr i} { after 100 }
        mkitsql::db::closeFile $db
    }
    open - open-bare {
        if {$mode eq "open-bare"} { proc ::mkitsql::db::takeLock {path} { return "" } }
        set rc [catch {mkitsql::db::openFile $f} msg opts]
        if {$rc} { say RESULT [dict get $opts -errorcode] [string map {\n { }} $msg] } else { say RESULT OPENED ; mkitsql::db::closeFile $msg }
    }
    raw-open {
        set rc [catch {mk::file open x $f -nocommit} msg opts]
        if {$rc} { say RESULT $::errorCode } else { say RESULT OPENED ; mk::file close x }
    }
    raw-commit {
        mk::file open x $f -nolock -nocommit
        mk::row append x.t k 777
        mk::file commit x
        mk::file close x
        say RESULT COMMITTED
    }
}
