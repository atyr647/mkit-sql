# mkitsql.tcl -- mkit-sql: standard SQL for Metakit databases.
#
#   source mkitsql.tcl           (or: package require mkitsql)
#
# Needs the ::store API of MK Studio (store.tcl) to be loaded; ::store is the
# only thing that talks to Mk4tcl.
#
# Drop-in for MK Studio's query layer:
#   ::mkitsql::parseScript text            -> list of {ast first end statementText}
#   ::mkitsql::execStatement ast defaultDb -> result dict (rowset / message)
#
# Convenience API:
#   ::mkitsql::run   sql ?defaultDb? ?params?   -> result of the last statement
#   ::mkitsql::query sql ?defaultDb? ?params?   -> {cols .. rows ..}  with NULL as "" unless -null given

package require Tcl 8.5

namespace eval ::mkitsql {
    variable version 0.1.0
    variable dir [file dirname [file normalize [info script]]]
}
foreach f {parser expr bind plan stmt} { source -encoding utf-8 [file join $::mkitsql::dir $f.tcl] }

# Run every statement in `text`; returns the result of the last one.
proc ::mkitsql::run {text {db ""} {params {}}} {
    set last ""
    foreach p [parseScript $text] { set last [execStatement [lindex $p 0] $db $params] }
    return $last
}

# Run one query and return {cols names rows rows}; NULL comes back as `nullValue`.
proc ::mkitsql::query {text {db ""} {params {}} {nullValue ""}} {
    variable nullText
    set saved $nullText
    set nullText $nullValue
    set rc [catch {run $text $db $params} res opts]
    set nullText $saved
    if {$rc} { return -options $opts $res }
    if {[dict get $res kind] ne "rowset"} { return [dict create cols {} rows {} message [dict get $res text]] }
    return [dict create cols [dict get $res cols] rows [dict get $res rows]]
}

package provide mkitsql $::mkitsql::version
