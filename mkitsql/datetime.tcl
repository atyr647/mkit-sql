# datetime.tcl -- DATE / TIME / TIMESTAMP and INTERVAL support for mkit-sql.
#
# Metakit has no date type: dates are stored as ISO-8601 text ("2026-03-05",
# "2026-03-05 14:30:00", "14:30:00") and compare correctly as text.
#
# An INTERVAL value exists only while a query runs.  Internally it is the string
#     ivl:<months>:<seconds>
# (months and seconds are kept apart because a month has no fixed length).  It is shown
# as  "1 year 2 mons 3 days 04:05:06"  and cannot be stored in a column.

namespace eval ::mkitsql {
    variable ivUnitSecs {second 1 minute 60 hour 3600 day 86400 week 604800}
}

proc ::mkitsql::ivMake {m s} {
    set m [expr {int($m)}]
    if {$s == int($s) && abs($s) < 1e15} { set s [expr {int($s)}] } else { set s [expr {double($s)}] }
    return ivl:$m:$s
}
proc ::mkitsql::ivSplit {v} {
    if {![regexp {^ivl:(-?\d+):(-?[0-9.eE+-]+)$} $v -> m s]} {
        fail "'[string range $v 0 40]' is not an interval"
    }
    return [list $m $s]
}
# seconds with 30-day months: the convention used to compare and sort intervals
proc ::mkitsql::ivTotal {v} { lassign [ivSplit $v] m s ; expr {$m * 2592000.0 + $s} }

# Human-readable form:  1 year 2 mons 3 days 04:05:06
proc ::mkitsql::ivFormat {v} {
    lassign [ivSplit $v] m s
    set parts {}
    set y [expr {$m / 12}] ; set mo [expr {$m % 12}]
    if {$m < 0 && $mo != 0} { set mo [expr {$mo - 12}] ; incr y }       ;# truncate toward zero
    if {$y} { lappend parts "$y year[expr {abs($y) == 1 ? {} : {s}}]" }
    if {$mo} { lappend parts "$mo mon[expr {abs($mo) == 1 ? {} : {s}}]" }
    set neg [expr {$s < 0}]
    set a [expr {abs($s)}]
    set d [expr {int($a / 86400)}]
    set rem [expr {$a - $d * 86400}]
    if {$d} { lappend parts "[expr {$neg ? -$d : $d}] day[expr {$d == 1 ? {} : {s}}]" }
    if {$rem > 0 || ![llength $parts]} {
        set hh [expr {int($rem / 3600)}] ; set mi [expr {int(($rem - $hh * 3600) / 60)}]
        set ss [expr {$rem - $hh * 3600 - $mi * 60}]
        if {$ss == int($ss)} { set sss [format %02d [expr {int($ss)}]] } else { set sss [format %09.6f $ss] ; set sss [string trimright $sss 0] }
        lappend parts "[expr {$neg ? {-} : {}}][format %02d $hh]:[format %02d $mi]:$sss"
    }
    return [join $parts " "]
}

# Parse the text of an interval literal.  `from`/`to` are the optional SQL qualifier
# (YEAR TO MONTH, DAY TO SECOND ...); without one, PostgreSQL-style text is accepted
# ('3 days', '1 year 2 months', '-5 hours', '1 day 02:30:00').  Returns {months seconds}.
proc ::mkitsql::ivParse {str from to} {
    variable ivUnitSecs
    set str [string trim $str]
    # leading zeros are decimal here ('08' DAY is 8 days), never octal
    regsub -all {(^|[^0-9.])0+(?=[0-9])} $str {\1} str
    set from [string tolower $from] ; set to [string tolower $to]
    set bad "Invalid interval '$str'"
    if {$from ne ""} {
        set sign 1
        if {[regexp {^([-+])(.*)$} $str -> sg rest]} { set str [string trim $rest] ; if {$sg eq "-"} { set sign -1 } }
        if {$to eq ""} {
            if {![regexp {^\d+(\.\d+)?$} $str]} { fail "$bad: expected a number of ${from}s" }
            if {$from eq "year"} { return [list [expr {$sign * int($str * 12)}] 0] }
            if {$from eq "month"} { return [list [expr {$sign * int($str)}] 0] }
            return [list 0 [expr {$sign * $str * [dict get $ivUnitSecs $from]}]]
        }
        if {$from eq "year" && $to eq "month"} {
            if {![regexp {^(\d+)-(\d+)$} $str -> y mo]} { fail "$bad: expected YEAR-MONTH, for example '1-2'" }
            return [list [expr {$sign * ([scan $y %d] * 12 + [scan $mo %d])}] 0]
        }
        set d 0 ; set h 0 ; set mi 0 ; set sec 0
        switch -- "$from $to" {
            "day hour"    { if {![regexp {^(\d+)\s+(\d+)$} $str -> d h]} { fail "$bad: expected 'D H'" } }
            "day minute"  { if {![regexp {^(\d+)\s+(\d+):(\d+)$} $str -> d h mi]} { fail "$bad: expected 'D H:M'" } }
            "day second"  { if {![regexp {^(\d+)\s+(\d+):(\d+):(\d+(?:\.\d+)?)$} $str -> d h mi sec]} { fail "$bad: expected 'D H:M:S'" } }
            "hour minute" { if {![regexp {^(\d+):(\d+)$} $str -> h mi]} { fail "$bad: expected 'H:M'" } }
            "hour second" { if {![regexp {^(\d+):(\d+):(\d+(?:\.\d+)?)$} $str -> h mi sec]} { fail "$bad: expected 'H:M:S'" } }
            "minute second" { if {![regexp {^(\d+):(\d+(?:\.\d+)?)$} $str -> mi sec]} { fail "$bad: expected 'M:S'" } }
            default { fail "Unsupported interval qualifier [string toupper $from] TO [string toupper $to]" }
        }
        foreach v {d h mi} { set $v [scan [set $v] %d] }
        return [list 0 [expr {$sign * ($d * 86400 + $h * 3600 + $mi * 60 + $sec)}]]
    }
    # PostgreSQL style
    set m 0 ; set s 0 ; set any 0
    set rest $str
    while {$rest ne ""} {
        if {[regexp {^\s*([-+]?\d+):(\d+)(?::(\d+(?:\.\d+)?))?(.*)$} $rest -> hh mi ss rest2]} {
            set sg [expr {[string index $hh 0] eq "-" ? -1 : 1}]
            set hh [expr {abs([scan [string trimleft $hh +-] %d])}]
            if {$ss eq ""} { set ss 0 }
            set s [expr {$s + $sg * ($hh * 3600 + [scan $mi %d] * 60 + $ss)}]
            set rest $rest2 ; set any 1 ; continue
        }
        if {[regexp -nocase {^\s*([-+]?\d+(?:\.\d+)?)\s*([a-z]+)(.*)$} $rest -> n u rest2]} {
            switch -glob -- [string tolower $u] {
                y - yr - yrs - year - years { set m [expr {$m + int($n * 12)}] }
                mon - mons - month - months { set m [expr {$m + int($n)}] }
                w - week - weeks { set s [expr {$s + $n * 604800}] }
                d - day - days { set s [expr {$s + $n * 86400}] }
                h - hr - hrs - hour - hours { set s [expr {$s + $n * 3600}] }
                min - mins - minute - minutes { set s [expr {$s + $n * 60}] }
                sec - secs - second - seconds { set s [expr {$s + $n}] }
                default { fail "$bad: unknown unit '$u'" }
            }
            set rest $rest2 ; set any 1 ; continue
        }
        fail $bad
    }
    if {!$any} { fail $bad }
    return [list $m $s]
}

# ---- dates -----------------------------------------------------------------
# Parse "YYYY-MM-DD", "YYYY-MM-DD HH:MM:SS[.fff]" or "HH:MM:SS" -> dict
proc ::mkitsql::dtParse {v} {
    if {[regexp {^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?\s*$} $v -> y m d hh mi ss]} {
        set kind [expr {$hh eq "" ? "date" : "timestamp"}]
        if {$hh eq ""} { set hh 0 ; set mi 0 } 
        if {$ss eq ""} { set ss 0 }
        return [dict create kind $kind y [scan $y %d] m [scan $m %d] d [scan $d %d] hh [scan $hh %d] mi [scan $mi %d] ss [normNum $ss]]
    }
    if {[regexp {^\s*(\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?\s*$} $v -> hh mi ss]} {
        if {$ss eq ""} { set ss 0 }
        return [dict create kind time y 1970 m 1 d 1 hh [scan $hh %d] mi [scan $mi %d] ss [normNum $ss]]
    }
    fail "'[string range $v 0 40]' is not a date or time (expected YYYY-MM-DD, YYYY-MM-DD HH:MM:SS or HH:MM:SS)"
}
proc ::mkitsql::daysInMonth {y m} {
    switch -- $m { 4 - 6 - 9 - 11 { return 30 } 2 { return [expr {($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0)) ? 29 : 28}] } }
    return 31
}
# Days since 1970-01-01 for a calendar date (proleptic Gregorian).  Plain integer arithmetic:
# nothing here depends on [clock], so results are identical on every Tcl version.
proc ::mkitsql::daysFromCivil {y m d} {
    if {$m <= 2} { incr y -1 }
    set era [expr {$y / 400}]                      ;# integer division floors, as needed for y < 0
    set yoe [expr {$y - $era * 400}]
    set doy [expr {(153 * ($m + ($m > 2 ? -3 : 9)) + 2) / 5 + $d - 1}]
    set doe [expr {$yoe * 365 + $yoe / 4 - $yoe / 100 + $doy}]
    return [expr {$era * 146097 + $doe - 719468}]
}
# {y m d} for a day count
proc ::mkitsql::civilFromDays {z} {
    incr z 719468
    set era [expr {$z / 146097}]
    set doe [expr {$z - $era * 146097}]
    set yoe [expr {($doe - $doe / 1460 + $doe / 36524 - $doe / 146096) / 365}]
    set y [expr {$yoe + $era * 400}]
    set doy [expr {$doe - (365 * $yoe + $yoe / 4 - $yoe / 100)}]
    set mp [expr {(5 * $doy + 2) / 153}]
    set d [expr {$doy - (153 * $mp + 2) / 5 + 1}]
    set m [expr {$mp + ($mp < 10 ? 3 : -9)}]
    if {$m <= 2} { incr y }
    return [list $y $m $d]
}
proc ::mkitsql::dtEpoch {p} {
    dict with p {}
    if {$m < 1 || $m > 12 || $d < 1 || $d > [daysInMonth $y $m]} { fail "Invalid date [format %04d-%02d-%02d $y $m $d]" }
    return [expr {[daysFromCivil $y $m $d] * 86400 + $hh * 3600 + $mi * 60 + $ss}]
}
# value + (months, seconds); month arithmetic clamps to the end of the month (Jan 31 + 1 month = Feb 28)
proc ::mkitsql::dtAdd {v months secs} {
    set p [dtParse $v]
    set kind [dict get $p kind]
    if {$kind eq "time"} {
        if {$months} { fail "A month interval cannot be added to a TIME" }
        set t [expr {(([dict get $p hh] * 3600 + [dict get $p mi] * 60 + [dict get $p ss]) + $secs)}]
        set t [expr {$t - floor($t / 86400.0) * 86400}]
        return [fmtSecs $t]
    }
    if {$months} {
        set tot [expr {[dict get $p y] * 12 + [dict get $p m] - 1 + $months}]
        set y [expr {int(floor($tot / 12.0))}] ; set m [expr {$tot - $y * 12 + 1}]
        set d [dict get $p d]
        set dm [daysInMonth $y $m]
        if {$d > $dm} { set d $dm }
        dict set p y $y ; dict set p m $m ; dict set p d $d
    }
    set e [expr {[dtEpoch $p] + $secs}]
    set whole [expr {$kind eq "date" && $secs == int($secs) && int($secs) % 86400 == 0}]
    set ef [expr {int(floor($e))}]
    set days [expr {$ef / 86400}] ; set rem [expr {$ef - $days * 86400}]
    lassign [civilFromDays $days] y m d
    set out [format %04d-%02d-%02d $y $m $d]
    if {!$whole} {
        append out [format " %02d:%02d:%02d" [expr {$rem / 3600}] [expr {$rem % 3600 / 60}] [expr {$rem % 60}]]
        set frac [expr {$e - floor($e)}]
        if {$frac > 0} { append out [string trimleft [format %.6f $frac] 0] }
    }
    return $out
}
proc ::mkitsql::fmtSecs {t} {
    set h [expr {int($t / 3600)}] ; set mi [expr {int(($t - $h * 3600) / 60)}] ; set s [expr {$t - $h * 3600 - $mi * 60}]
    if {$s == int($s)} { return [format %02d:%02d:%02d $h $mi [expr {int($s)}]] }
    return [format %02d:%02d:%09.6f $h $mi $s]
}

# ---- runtime procs ------------------------------------------------------------
::mkitsql::defstrict iv_add {a b} { lassign [::mkitsql::ivSplit $a] m1 s1 ; lassign [::mkitsql::ivSplit $b] m2 s2 ; ::mkitsql::ivMake [expr {$m1 + $m2}] [expr {$s1 + $s2}] }
::mkitsql::defstrict iv_sub {a b} { lassign [::mkitsql::ivSplit $a] m1 s1 ; lassign [::mkitsql::ivSplit $b] m2 s2 ; ::mkitsql::ivMake [expr {$m1 - $m2}] [expr {$s1 - $s2}] }
::mkitsql::defstrict iv_neg {a} { lassign [::mkitsql::ivSplit $a] m s ; ::mkitsql::ivMake [expr {-$m}] [expr {-$s}] }
::mkitsql::defstrict iv_mul {a n} { lassign [::mkitsql::ivSplit $a] m s ; ::mkitsql::ivMake [expr {round($m * $n)}] [expr {$s * $n}] }
::mkitsql::defstrict iv_div {a n} {
    if {$n == 0} { ::mkitsql::fail "Division by zero" }
    lassign [::mkitsql::ivSplit $a] m s ; ::mkitsql::ivMake [expr {round($m / double($n))}] [expr {$s / double($n)}]
}
::mkitsql::defstrict iv_fmt {a} { ::mkitsql::ivFormat $a }
::mkitsql::defstrict dt_add_iv {d iv} { lassign [::mkitsql::ivSplit $iv] m s ; ::mkitsql::dtAdd $d $m $s }
::mkitsql::defstrict dt_sub_iv {d iv} { lassign [::mkitsql::ivSplit $iv] m s ; ::mkitsql::dtAdd $d [expr {-$m}] [expr {-$s}] }
::mkitsql::defstrict dt_sub {a b} {
    set pa [::mkitsql::dtParse $a] ; set pb [::mkitsql::dtParse $b]
    ::mkitsql::ivMake 0 [expr {[::mkitsql::dtEpoch $pa] - [::mkitsql::dtEpoch $pb]}]
}
::mkitsql::defstrict cast_interval {v} {
    if {[string match ivl:* $v]} { return $v }
    lassign [::mkitsql::ivParse $v "" ""] m s
    ::mkitsql::ivMake $m $s
}
foreach {nm op} {eq == ne != lt < le <= gt > ge >=} {
    ::mkitsql::defstrict ${nm}_i {a b} "expr {\[::mkitsql::ivTotal \$a\] $op \[::mkitsql::ivTotal \$b\]}"
}

# EXTRACT(field FROM interval)
proc ::mkitsql::ivExtract {field v} {
    lassign [ivSplit $v] m s
    switch -- $field {
        YEAR   { return [expr {int($m / 12)}] }
        MONTH  { return [expr {int($m - int($m / 12) * 12)}] }
        DAY    { return [expr {int($s / 86400)}] }
        HOUR   { return [expr {int(($s - int($s / 86400) * 86400) / 3600)}] }
        MINUTE { return [expr {int(($s - int($s / 3600) * 3600) / 60)}] }
        SECOND { set r [expr {$s - int($s / 60) * 60}] ; if {$r == int($r)} { return [expr {int($r)}] } ; return $r }
        EPOCH  { return [ivTotal $v] }
    }
    fail "Unknown EXTRACT field '$field' for an interval"
}
