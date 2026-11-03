# Loads the engine for a test script.
#   default                 MK Studio's store.tcl (tests/vendor) + mkitsql  -> engine uses db_studio.tcl
#   MKIT_BACKEND=standalone no store.tcl at all: mkitsql on its own storage layer (db.tcl)
# In standalone mode a tiny ::store shim lets the tests keep their setup code (openFile, createSample, ...).
set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
if {[info exists ::env(MKIT_BACKEND)] && $::env(MKIT_BACKEND) eq "standalone"} {
    source $root/mkitsql/mkitsql.tcl
    if {$::mkitsql::backend ne "standalone"} { error "expected the standalone backend" }
    namespace eval ::store {}
    foreach p {tags views hasView layout size rows openFile closeFile createView appendRow dropView commit rollback dirty setCell path subSize deleteRows restructure parseLayout formatLayout} {
        proc ::store::$p args "::mkitsql::db::$p {*}\$args"
    }
    # createSample is plain setup code written against these names
    set in [open $here/vendor/store.tcl] ; set txt [read $in] ; close $in
    set i [string first "# -- a small sample database" $txt]
    namespace eval ::store [string range $txt $i end]
    puts "(backend: standalone)"
} else {
    source $here/vendor/store.tcl
    source $root/mkitsql/mkitsql.tcl
}
