# mkql_compat.tcl -- lets MK Studio use mkit-sql in place of its built-in MKQL.
#
# In mkstudio's  lib/app-mkstudio/loader.tcl  replace the `mkql` entry by:
#
#     source /path/to/mkitsql/mkitsql.tcl
#     source /path/to/mkitsql/mkql_compat.tcl
#
# (loaded after `store`, before `grid editor explorer docs app`).  MK Studio only
# touches the names below; everything else it does goes through ::store.

namespace eval ::mkql {
    # shared state: the UI sets these, the engine reads them
    namespace upvar ::mkitsql cancel cancel maxRows maxRows progressHook progressHook \
        keywords keywords aggs aggs functions functions tokenRe tokenRe
}

proc ::mkql::parseScript {text} { ::mkitsql::parseScript $text }
proc ::mkql::execStatement {ast defaultDb} { ::mkitsql::execStatement $ast $defaultDb }
proc ::mkql::run {text {defaultDb ""}} { ::mkitsql::run $text $defaultDb }

# three-way comparison used by the result grid when sorting a column:
# numbers numerically, everything else as text
proc ::mkql::compare {a b} {
    set re {^\s*[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\s*$}
    if {[regexp $re $a] && [regexp $re $b]} {
        set x [expr {double([string trim $a])}] ; set y [expr {double([string trim $b])}]
        return [expr {$x < $y ? -1 : $x > $y ? 1 : 0}]
    }
    set c [string compare -nocase $a $b]
    if {$c == 0} { set c [string compare $a $b] }
    return $c
}
