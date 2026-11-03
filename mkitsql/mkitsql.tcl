# mkitsql.tcl -- mkit-sql: standard SQL for Metakit databases.
#
#   source mkitsql.tcl           (or: package require mkitsql)
#
# Storage: talks to Mk4tcl through ::mkitsql::db (db.tcl); inside MK Studio it forwards to MK Studio's
# ::store instead (db_studio.tcl).  Nothing else in the engine touches Mk4tcl.
#
# Engine API (what MK Studio uses; see engine_studio.tcl):
#   ::mkitsql::parseScript text                    -> list of {ast first end statementText}
#   ::mkitsql::execStatement ast ?defaultDb? ?params? -> result dict (rowset / message)
#
# Convenience API:
#   ::mkitsql::run   sql ?defaultDb? ?params?              -> result of the last statement
#   ::mkitsql::query sql ?defaultDb? ?params? ?nullValue?  -> {cols .. rows ..}
#
# params: a list for `?` placeholders, a dict for `:name` placeholders (the statement says which it uses).
# nulls:  the parameters that are NULL - positions (1, 2, ..) for `?`, names for `:name`.  A parameter value
#         is never interpreted: no text, however it is spelled, can turn into NULL (and U+FDD0 is rejected).

package require Tcl 8.5-10

namespace eval ::mkitsql {
    variable version 0.4.0
    variable dir [file dirname [file normalize [info script]]]
}
foreach f {parser expr datetime verify bind plan spill exec window stmt dbcheck} { source -encoding utf-8 [file join $::mkitsql::dir $f.tcl] }

# The storage layer.  Standalone (db.tcl, straight on Mk4tcl) unless MK Studio's ::store is already
# loaded, in which case the files are shared with it through db_studio.tcl.  Force one with
#     set ::mkitsql::backend standalone|studio     (before loading)    or the MKIT_BACKEND environment variable.
namespace eval ::mkitsql {
    if {![info exists backend]} { variable backend [expr {[info exists ::env(MKIT_BACKEND)] ? $::env(MKIT_BACKEND) : "auto"}] }
    if {$backend eq "auto"} { set backend [expr {[llength [info commands ::store::tags]] ? "studio" : "standalone"}] }
    if {$backend eq "studio"} {
        source -encoding utf-8 [file join $dir dbcommon.tcl]
        source -encoding utf-8 [file join $dir db_studio.tcl]
    } elseif {$backend eq "standalone"} {
        if {![llength [info commands ::mk::file]]} { catch {package require Mk4tcl} }
        source -encoding utf-8 [file join $dir dbcommon.tcl]
        source -encoding utf-8 [file join $dir db.tcl]
    } else {
        error "::mkitsql::backend must be auto, standalone or studio, not '$backend'"
    }
}

# Run every statement in `text`; returns the result of the last one.
proc ::mkitsql::run {text {db ""} {params {}} {nulls {}}} {
    set last ""
    foreach p [parseScript $text] { set last [execStatement [lindex $p 0] $db $params $nulls] }
    return $last
}

# Run one SELECT and hand the rows to `callback` in chunks (a list of rows per call) without ever
# holding the result: memory stays flat however big the table is.  The callback returns 1 to stop.
# NULL is passed as `nullValue`.  Returns {cols .. types .. count N}.
#     ::mkitsql::stream {SELECT * FROM big ORDER BY val} $db {} {myproc} 
proc ::mkitsql::stream {text {db ""} {params {}} {callback ""} {nullValue ""} {nulls {}}} {
    variable streamCb
    set parsed [parseScript $text]
    if {[llength $parsed] != 1 || [lindex $parsed 0 0 0] ne "select"} { fail "stream takes exactly one SELECT statement" }
    set streamCb [list $callback $nullValue]
    set rc [catch {execStatement [lindex $parsed 0 0] $db $params $nulls} res opts]
    set streamCb ""
    if {$rc} { return -options $opts $res }
    return $res
}

# Run one query and return {cols names rows rows}; NULL comes back as `nullValue`.
proc ::mkitsql::query {text {db ""} {params {}} {nullValue ""} {nulls {}}} {
    variable nullText
    set saved $nullText
    set nullText $nullValue
    set rc [catch {run $text $db $params $nulls} res opts]
    set nullText $saved
    if {$rc} { return -options $opts $res }
    if {[dict get $res kind] ne "rowset"} { return [dict create cols {} rows {} message [dict get $res text]] }
    return [dict create cols [dict get $res cols] rows [dict get $res rows]]
}

package provide mkitsql $::mkitsql::version
