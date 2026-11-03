# expr.tcl -- expression compiler and runtime for mkit-sql.
#
# A bound expression tree is compiled into the text of a small Tcl proc, so
# evaluating it per row costs a handful of proc calls instead of a recursive
# interpreter walk.  Values are plain Tcl strings; SQL NULL is the sentinel
# string  "\uE000NULL"  (see ::mkitsql::N).  Metakit itself has no NULL: NULLs
# only arise during evaluation (LEFT JOIN, SELECT NULL, empty aggregates ...)
# and are turned into the column default (0 / "") when written back.
#
# Static types:  int real text blob bool null
#   - comparison and arithmetic are chosen from the static types, so
#     '2' < '10' is a *text* comparison and 7 / 2 is integer division (= 3),
#     exactly as standard SQL says.
#
# Bound expression nodes (produced by the binder in query.tcl):
#   {lit T V}  {ref LEVEL SRC NAME TYPE}  {slot POS TYPE}  {un OP e}  {bin OP a b}
#   {isnull e neg} {istf e val neg} {isdist a b neg} {between e lo hi neg}
#   {like e pat esc neg ci} {in e list neg} {insub e planId neg} {exists planId}
#   {sub planId type} {case operand whens else} {cast e type} {func NAME distinct args}

namespace eval ::mkitsql {
    variable N "\uE000NULL"
    variable cxCount 0
    variable likeCache
    array set likeCache {}
    variable planCorr
    array set planCorr {}
}
namespace eval ::mkitsql::rt {}
namespace eval ::mkitsql::cx {}

# ============================================================================
#  Runtime helpers  (called from compiled code)
# ============================================================================
# Define a runtime proc whose listed arguments are NULL-strict: if any is NULL
# the result is NULL without running the body.
proc ::mkitsql::defstrict {name arglist body} {
    set chk {}
    foreach a $arglist { lappend chk "\$[lindex $a 0] eq \"\\uE000NULL\"" }
    proc ::mkitsql::rt::$name $arglist "if \{[join $chk { || }]\} \{return \"\\uE000NULL\"\}\n$body"
}

proc ::mkitsql::rt::isnull  {v} { expr {$v eq "\uE000NULL"} }
proc ::mkitsql::rt::notnull {v} { expr {$v ne "\uE000NULL"} }
proc ::mkitsql::rt::not {v} { if {$v eq "\uE000NULL"} { return $v } ; expr {!$v} }
proc ::mkitsql::rt::and2 {a b} {
    # a is known not to be 0
    if {$b eq "0"} { return 0 }
    if {$a eq "\uE000NULL" || $b eq "\uE000NULL"} { return "\uE000NULL" }
    return 1
}
proc ::mkitsql::rt::or2 {a b} {
    # a is known not to be 1
    if {$b eq "1"} { return 1 }
    if {$a eq "\uE000NULL" || $b eq "\uE000NULL"} { return "\uE000NULL" }
    return 0
}
# numeric value in boolean context -> 1 / 0 / NULL
proc ::mkitsql::rt::tobool {v} {
    if {$v eq "\uE000NULL"} { return $v }
    expr {$v != 0}
}
proc ::mkitsql::rt::istf {v want neg} {
    if {$v eq "\uE000NULL"} { return $neg }
    expr {(($v != 0) == $want) ^ $neg}
}
proc ::mkitsql::rt::isdist {a b neg} {
    set an [expr {$a eq "\uE000NULL"}] ; set bn [expr {$b eq "\uE000NULL"}]
    if {$an || $bn} { return [expr {($an != $bn) ^ $neg}] }
    expr {($a ne $b) ^ $neg}
}

# ---- numbers ---------------------------------------------------------------
# Convert text to a number (used when a text value meets an arithmetic operator).
proc ::mkitsql::rt::num {v} {
    if {$v eq "\uE000NULL"} { return $v }
    set s [string trim $v]
    if {![regexp {^[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$} $s]} {
        ::mkitsql::fail "Invalid number: '[string range $v 0 40]'"
    }
    regsub {^([-+]?)0+(?=\d)} $s {\1} s
    if {[regexp {^[-+]?\d+$} $s]} { return [expr {$s + 0}] }
    return [expr {double($s)}]
}
::mkitsql::defstrict neg {a} { expr {-$a} }
::mkitsql::defstrict add {a b} { expr {$a + $b} }
::mkitsql::defstrict sub {a b} { expr {$a - $b} }
::mkitsql::defstrict mul {a b} { expr {$a * $b} }
::mkitsql::defstrict idiv {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    set q [expr {abs($a) / abs($b)}]
    if {($a < 0) != ($b < 0)} { set q [expr {-$q}] }
    return $q
}
::mkitsql::defstrict rdiv {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    expr {double($a) / $b}
}
::mkitsql::defstrict imod {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    set r [expr {abs($a) % abs($b)}]
    if {$a < 0} { set r [expr {-$r}] }
    return $r
}
::mkitsql::defstrict rmod {a b} {
    if {$b == 0} { ::mkitsql::fail "Division by zero" }
    expr {fmod($a, $b)}
}
::mkitsql::defstrict concat {a b} { return $a$b }

# ---- comparison ------------------------------------------------------------
# n = numeric, s = text/blob, m = mixed (text vs number: compare as numbers when
# the text is numeric, otherwise as text).
foreach {nm op} {eq == ne != lt < le <= gt > ge >=} {
    ::mkitsql::defstrict ${nm}_n {a b} "expr {\$a $op \$b}"
    ::mkitsql::defstrict ${nm}_s {a b} "expr {\[string compare \$a \$b\] $op 0}"
    ::mkitsql::defstrict ${nm}_m {a b} "
        if {\[::mkitsql::rt::looksnum \$a\] && \[::mkitsql::rt::looksnum \$b\]} {
            return \[expr {\[::mkitsql::rt::num \$a\] $op \[::mkitsql::rt::num \$b\]}\]
        }
        expr {\[string compare \$a \$b\] $op 0}"
}
proc ::mkitsql::rt::looksnum {v} {
    regexp {^\s*[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?\s*$} $v
}

# ---- LIKE ------------------------------------------------------------------
proc ::mkitsql::likeRegexp {pat esc} {
    variable likeCache
    if {[info exists likeCache($pat,$esc)]} { return $likeCache($pat,$esc) }
    set re "^"
    set n [string length $pat]
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $pat $i]
        if {$esc ne "" && $c eq $esc && $i + 1 < $n} {
            incr i
            append re [regsub -all {[][\\.^$*+?(){}|]} [string index $pat $i] {\\&}]
        } elseif {$c eq "%"} { append re ".*"
        } elseif {$c eq "_"} { append re "."
        } else { append re [regsub -all {[][\\.^$*+?(){}|]} $c {\\&}] }
    }
    append re "\$"
    if {[array size likeCache] > 500} { array unset likeCache }
    set likeCache($pat,$esc) "(?s)$re"
    return $likeCache($pat,$esc)
}
proc ::mkitsql::rt::like {v pat esc ci} {
    if {$v eq "\uE000NULL" || $pat eq "\uE000NULL" || $esc eq "\uE000NULL"} { return "\uE000NULL" }
    set re [::mkitsql::likeRegexp $pat $esc]
    if {$ci} { return [regexp -nocase -- $re $v] }
    return [regexp -- $re $v]
}

# ---- IN with a literal list ------------------------------------------------
proc ::mkitsql::rt::inlist {v list kind hasNull} {
    if {$v eq "\uE000NULL"} { return $v }
    switch -- $kind {
        n { set hit [expr {[lsearch -exact -real $list $v] >= 0}] }
        default { set hit [expr {[lsearch -exact -ascii $list $v] >= 0}] }
    }
    if {$hit} { return 1 }
    if {$hasNull} { return "\uE000NULL" }
    return 0
}

# ---- CASTs -----------------------------------------------------------------
::mkitsql::defstrict cast_int {v} {
    set v [::mkitsql::rt::num $v]
    if {[string is integer -strict $v] || [string is wideinteger -strict $v]} { return $v }
    expr {round($v)}
}
::mkitsql::defstrict cast_real {v} { expr {double([::mkitsql::rt::num $v])} }
::mkitsql::defstrict cast_text {v} { return $v }
::mkitsql::defstrict cast_blob {v} { return $v }
::mkitsql::defstrict cast_bool {v} {
    switch -- [string tolower [string trim $v]] {
        t - true - yes - y - on - 1 { return 1 }
        f - false - no - n - off - 0 { return 0 }
    }
    if {[::mkitsql::rt::looksnum $v]} { return [expr {[::mkitsql::rt::num $v] != 0}] }
    ::mkitsql::fail "Invalid boolean: '[string range $v 0 40]'"
}
::mkitsql::defstrict cast_date {v} {
    if {![regexp {^\s*(\d{4})-(\d{1,2})-(\d{1,2})} $v -> y m d]} {
        ::mkitsql::fail "Invalid date: '[string range $v 0 40]' (expected YYYY-MM-DD)"
    }
    return [format %04d-%02d-%02d $y [scan $m %d] [scan $d %d]]
}
::mkitsql::defstrict cast_timestamp {v} {
    if {![regexp {^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?} $v -> y m d hh mi ss]} {
        ::mkitsql::fail "Invalid timestamp: '[string range $v 0 40]' (expected YYYY-MM-DD HH:MM:SS)"
    }
    if {$hh eq ""} { set hh 0 ; set mi 0 ; set ss 0 }
    if {$ss eq ""} { set ss 0 }
    if {[string first . $ss] >= 0} {
        return [format "%04d-%02d-%02d %02d:%02d:%s" $y [scan $m %d] [scan $d %d] [scan $hh %d] [scan $mi %d] $ss]
    }
    return [format "%04d-%02d-%02d %02d:%02d:%02d" $y [scan $m %d] [scan $d %d] [scan $hh %d] [scan $mi %d] [scan $ss %d]]
}
::mkitsql::defstrict cast_time {v} {
    if {![regexp {^\s*(\d{1,2}):(\d{2})(?::(\d{2}))?} $v -> hh mi ss]} {
        ::mkitsql::fail "Invalid time: '[string range $v 0 40]' (expected HH:MM:SS)"
    }
    if {$ss eq ""} { set ss 0 }
    return [format %02d:%02d:%02d [scan $hh %d] [scan $mi %d] [scan $ss %d]]
}

# ---- scalar functions ------------------------------------------------------
::mkitsql::defstrict fn_ABS {a} { expr {abs($a)} }
::mkitsql::defstrict fn_SIGN {a} { expr {$a > 0 ? 1 : ($a < 0 ? -1 : 0)} }
::mkitsql::defstrict fn_CEIL {a} { if {[string is integer -strict $a]} { return $a } ; expr {ceil($a)} }
::mkitsql::defstrict fn_FLOOR {a} { if {[string is integer -strict $a]} { return $a } ; expr {floor($a)} }
::mkitsql::defstrict fn_ROUND {a {n 0}} {
    if {[string is integer -strict $a] && $n >= 0} { return $a }
    if {$n == 0} { return [expr {double(round($a))}] }
    if {$n > 0} { return [expr {double([format %.${n}f $a])}] }
    set k [expr {10.0 ** (-$n)}]
    expr {double(round($a / $k) * $k)}
}
::mkitsql::defstrict fn_TRUNC {a {n 0}} {
    if {[string is integer -strict $a] && $n >= 0} { return $a }
    if {$n >= 0} {
        set k [expr {10.0 ** $n}]
        return [expr {double(int($a * $k)) / $k}]
    }
    set k [expr {10.0 ** (-$n)}]
    expr {double(int($a / $k)) * $k}
}
::mkitsql::defstrict fn_SQRT {a} {
    if {$a < 0} { ::mkitsql::fail "Cannot take square root of a negative number" }
    expr {sqrt($a)}
}
::mkitsql::defstrict fn_POWER {a b} { expr {double($a) ** $b} }
::mkitsql::defstrict fn_EXP {a} { expr {exp($a)} }
::mkitsql::defstrict fn_LN {a} {
    if {$a <= 0} { ::mkitsql::fail "Cannot take logarithm of zero or a negative number" }
    expr {log($a)}
}
::mkitsql::defstrict fn_LOG10 {a} {
    if {$a <= 0} { ::mkitsql::fail "Cannot take logarithm of zero or a negative number" }
    expr {log10($a)}
}
::mkitsql::defstrict fn_SIN {a} { expr {sin($a)} }
::mkitsql::defstrict fn_COS {a} { expr {cos($a)} }
::mkitsql::defstrict fn_TAN {a} { expr {tan($a)} }
::mkitsql::defstrict fn_ASIN {a} { expr {asin($a)} }
::mkitsql::defstrict fn_ACOS {a} { expr {acos($a)} }
::mkitsql::defstrict fn_ATAN {a} { expr {atan($a)} }
::mkitsql::defstrict fn_ATAN2 {a b} { expr {atan2($a, $b)} }
::mkitsql::defstrict fn_DEGREES {a} { expr {$a * 180.0 / 3.141592653589793} }
::mkitsql::defstrict fn_RADIANS {a} { expr {$a * 3.141592653589793 / 180.0} }
proc ::mkitsql::rt::fn_ROWID_ {cur} { lindex [split $cur !] end }
proc ::mkitsql::rt::fn_PI {} { return 3.141592653589793 }
proc ::mkitsql::rt::fn_RANDOM {} { expr {rand()} }

::mkitsql::defstrict fn_LENGTH {a} { string length $a }
::mkitsql::defstrict fn_OCTET_LENGTH {a} { string length [encoding convertto utf-8 $a] }
::mkitsql::defstrict fn_UPPER {a} { string toupper $a }
::mkitsql::defstrict fn_LOWER {a} { string tolower $a }
::mkitsql::defstrict fn_INITCAP {a} {
    set out "" ; set up 1
    foreach c [split $a ""] {
        if {[string is alnum $c]} {
            append out [expr {$up ? [string toupper $c] : [string tolower $c]}] ; set up 0
        } else { append out $c ; set up 1 }
    }
    return $out
}
::mkitsql::defstrict fn_TRIM_ {mode chars v} {
    switch -- $mode {
        leading  { return [string trimleft $v $chars] }
        trailing { return [string trimright $v $chars] }
    }
    string trim $v $chars
}
::mkitsql::defstrict fn_LTRIM {v {chars " "}} { string trimleft $v $chars }
::mkitsql::defstrict fn_RTRIM {v {chars " "}} { string trimright $v $chars }
::mkitsql::defstrict fn_REPLACE {s from to} {
    if {$from eq ""} { return $s }
    string map [list $from $to] $s
}
# SUBSTR(s, start [, len])  -- 1-based; follows the SQL standard for
# out-of-range start / length.
::mkitsql::defstrict fn_SUBSTR {s start {len ""}} {
    if {$len eq "\uE000NULL"} { return $len }
    set from $start
    if {$len eq ""} {
        set to [string length $s]
    } else {
        if {$len < 0} { ::mkitsql::fail "Negative substring length not allowed" }
        set to [expr {$start + $len - 1}]
    }
    if {$from < 1} { set from 1 }
    if {$to > [string length $s]} { set to [string length $s] }
    if {$to < $from} { return "" }
    string range $s [expr {$from - 1}] [expr {$to - 1}]
}
::mkitsql::defstrict fn_LEFT {s n} { string range $s 0 [expr {$n - 1}] }
::mkitsql::defstrict fn_RIGHT {s n} {
    if {$n <= 0} { return "" }
    string range $s [expr {[string length $s] - $n}] end
}
::mkitsql::defstrict fn_POSITION {needle hay} { expr {[string first $needle $hay] + 1} }
::mkitsql::defstrict fn_REPEAT {s n} { string repeat $s [expr {$n < 0 ? 0 : $n}] }
::mkitsql::defstrict fn_REVERSE {s} {
    set out ""
    foreach c [split $s ""] { set out $c$out }
    return $out
}
::mkitsql::defstrict fn_LPAD {s n {fill " "}} {
    set len [string length $s]
    if {$n <= $len} { return [string range $s 0 [expr {$n - 1}]] }
    if {$fill eq ""} { return $s }
    set pad [string range [string repeat $fill [expr {($n - $len) / [string length $fill] + 1}]] 0 [expr {$n - $len - 1}]]
    return $pad$s
}
::mkitsql::defstrict fn_RPAD {s n {fill " "}} {
    set len [string length $s]
    if {$n <= $len} { return [string range $s 0 [expr {$n - 1}]] }
    if {$fill eq ""} { return $s }
    set pad [string range [string repeat $fill [expr {($n - $len) / [string length $fill] + 1}]] 0 [expr {$n - $len - 1}]]
    return $s$pad
}
::mkitsql::defstrict fn_ASCII {s} { if {$s eq ""} { return 0 } ; scan [string index $s 0] %c }
::mkitsql::defstrict fn_CHR {n} { format %c $n }
proc ::mkitsql::rt::fn_CONCAT {args} {
    set out ""
    foreach a $args { if {$a ne "\uE000NULL"} { append out $a } }
    return $out
}
proc ::mkitsql::rt::fn_CONCAT_WS {sep args} {
    if {$sep eq "\uE000NULL"} { return $sep }
    set parts {}
    foreach a $args { if {$a ne "\uE000NULL"} { lappend parts $a } }
    return [join $parts $sep]
}
proc ::mkitsql::rt::fn_NULLIF {a b eqproc} {
    if {$a eq "\uE000NULL"} { return $a }
    if {[$eqproc $a $b] eq "1"} { return "\uE000NULL" }
    return $a
}
# GREATEST / LEAST ignore NULLs (as PostgreSQL does); kind n = numeric, s = text.
proc ::mkitsql::rt::fn_GREATEST {kind args} {
    set best "\uE000NULL"
    foreach a $args {
        if {$a eq "\uE000NULL"} continue
        if {$best eq "\uE000NULL"} { set best $a ; continue }
        if {$kind eq "n" ? $a > $best : [string compare $a $best] > 0} { set best $a }
    }
    return $best
}
proc ::mkitsql::rt::fn_LEAST {kind args} {
    set best "\uE000NULL"
    foreach a $args {
        if {$a eq "\uE000NULL"} continue
        if {$best eq "\uE000NULL"} { set best $a ; continue }
        if {$kind eq "n" ? $a < $best : [string compare $a $best] < 0} { set best $a }
    }
    return $best
}

# date / time
proc ::mkitsql::rt::fn_CURRENT_DATE {} { clock format [clock seconds] -format %Y-%m-%d }
proc ::mkitsql::rt::fn_CURRENT_TIME {} { clock format [clock seconds] -format %H:%M:%S }
proc ::mkitsql::rt::fn_CURRENT_TIMESTAMP {} { clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S" }
::mkitsql::defstrict fn_EXTRACT {field v} {
    if {![regexp {^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?} $v -> y m d hh mi ss]} {
        if {[regexp {^\s*(\d{1,2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?} $v -> hh mi ss]} {
            set y "" ; set m "" ; set d ""
        } else {
            ::mkitsql::fail "Cannot extract from '[string range $v 0 40]': not a date or time"
        }
    }
    foreach x {hh mi ss} { if {[set $x] eq ""} { set $x 0 } }
    switch -- $field {
        YEAR   { return [scan $y %d] }
        MONTH  { return [scan $m %d] }
        DAY    { return [scan $d %d] }
        HOUR   { return [scan $hh %d] }
        MINUTE { return [scan $mi %d] }
        SECOND { return $ss }
        DOW    { return [clock format [clock scan "$y-$m-$d" -format %Y-%m-%d -gmt 1] -format %w -gmt 1] }
        DOY    { return [scan [clock format [clock scan "$y-$m-$d" -format %Y-%m-%d -gmt 1] -format %j -gmt 1] %d] }
        EPOCH  {
            return [clock scan [format "%04d-%02d-%02d %02d:%02d:%02d" $y [scan $m %d] [scan $d %d] [scan $hh %d] [scan $mi %d] [expr {int($ss)}]] \
                -format "%Y-%m-%d %H:%M:%S" -gmt 1]
        }
    }
    ::mkitsql::fail "Unknown EXTRACT field '$field'"
}

# ============================================================================
#  Types
# ============================================================================
proc ::mkitsql::isNumType {t} { expr {$t in {int real bool}} }

proc ::mkitsql::unify {a b} {
    if {$a eq $b} { return $a }
    if {$a eq "null"} { return $b }
    if {$b eq "null"} { return $a }
    if {$a in {int bool} && $b in {int bool}} { return int }
    if {[isNumType $a] && [isNumType $b]} { return real }
    if {$a eq "blob" && $b eq "blob"} { return blob }
    return text
}

# Metakit column letter -> static type
proc ::mkitsql::typeOfLetter {l} {
    switch -- $l {
        I - L { return int }
        F - D { return real }
        B { return blob }
        default { return text }
    }
}
# static type -> display letter for grids ("" = unknown)
proc ::mkitsql::letterOfType {t} {
    switch -- $t { int - bool { return N } real { return N } blob { return B } }
    return ""
}

# SQL type name (from CAST / CREATE TABLE) -> {metakitLetter staticType castKind}
proc ::mkitsql::sqlType {name} {
    switch -- $name {
        int - integer - smallint - tinyint - mediumint { return {I int int} }
        bigint - long { return {L int int} }
        real - float4 { return {F real real} }
        float - double - float8 - decimal - numeric - dec - number { return {D real real} }
        boolean - bool { return {I bool bool} }
        varchar - char - text - string - clob - nvarchar - nchar - character - bpchar { return {S text text} }
        blob - binary - varbinary - bytes - bytea - bit { return {B blob blob} }
        date { return {S text date} }
        time { return {S text time} }
        timestamp - datetime { return {S text timestamp} }
    }
    fail "Unknown type '$name'. Supported: INT, BIGINT, REAL, DOUBLE, DECIMAL/NUMERIC, BOOLEAN, VARCHAR/TEXT, BLOB, DATE, TIME, TIMESTAMP"
}

# ============================================================================
#  Code generation
# ============================================================================
# Every cg* returns {word type}: `word` is a Tcl command-argument word (a
# literal or a [command substitution]) that yields the value when evaluated
# inside a proc whose arguments are  r0 (current tuple) and outer (list of
# enclosing tuples, nearest first).

proc ::mkitsql::cgFail {msg} { fail $msg }

# coerce a {word type} pair to a boolean word
proc ::mkitsql::asBool {wt ctxName} {
    lassign $wt w t
    switch -- $t {
        bool - null { return $w }
        int - real  { return "\[::mkitsql::rt::tobool $w\]" }
    }
    fail "Argument of $ctxName must be a boolean or a number, not text"
}
# coerce to a numeric word (casting text)
proc ::mkitsql::asNum {wt} {
    lassign $wt w t
    if {$t in {int real bool null}} { return $wt }
    return [list "\[::mkitsql::rt::num $w\]" real]
}
proc ::mkitsql::asText {wt} {
    lassign $wt w t
    return [list $w text]
}

proc ::mkitsql::cg {node ctx} {
    variable N
    switch -- [lindex $node 0] {
        lit {
            lassign $node _ ty v
            if {$ty eq "null"} { return [list [list $N] null] }
            return [list [list $v] $ty]
        }
        ref {
            lassign $node _ level src name ty
            set pos [ctxPos $ctx $level $src $name]
            if {$level == 0} { return [list "\[lindex \$r0 $pos\]" $ty] }
            return [list "\[lindex \[lindex \$outer [expr {$level - 1}]\] $pos\]" $ty]
        }
        slot {
            lassign $node _ pos ty
            return [list "\[lindex \$r0 $pos\]" $ty]
        }
        un {
            lassign $node _ op e
            set a [cg $e $ctx]
            if {$op eq "not"} {
                return [list "\[::mkitsql::rt::not [asBool $a NOT]\]" bool]
            }
            lassign [asNum $a] w t
            return [list "\[::mkitsql::rt::neg $w\]" $t]
        }
        bin { return [cgBin $node $ctx] }
        isnull {
            lassign $node _ e neg
            set w [lindex [cg $e $ctx] 0]
            return [list "\[::mkitsql::rt::[expr {$neg ? {notnull} : {isnull}}] $w\]" bool]
        }
        istf {
            lassign $node _ e val neg
            set a [cg $e $ctx]
            if {[lindex $a 1] eq "text"} { fail "IS TRUE / IS FALSE needs a boolean or a number" }
            return [list "\[::mkitsql::rt::istf [lindex $a 0] $val $neg\]" bool]
        }
        isdist {
            lassign $node _ a b neg
            set wa [lindex [cg $a $ctx] 0] ; set wb [lindex [cg $b $ctx] 0]
            return [list "\[::mkitsql::rt::isdist $wa $wb $neg\]" bool]
        }
        between {
            lassign $node _ e lo hi neg
            set ge [list bin >= $e $lo] ; set le [list bin <= $e $hi]
            set both [list bin and $ge $le]
            if {$neg} { set both [list un not $both] }
            return [cg $both $ctx]
        }
        like {
            lassign $node _ e pat esc neg ci
            set a [cg $e $ctx] ; set p [cg $pat $ctx]
            set escw [expr {$esc eq "" ? [list {}] : [lindex [cg $esc $ctx] 0]}]
            set code "\[::mkitsql::rt::like [lindex $a 0] [lindex $p 0] $escw $ci\]"
            if {$neg} { set code "\[::mkitsql::rt::not $code\]" }
            return [list $code bool]
        }
        in { return [cgIn $node $ctx] }
        insub {
            lassign $node _ e bq neg refs
            set a [cg $e $ctx]
            set id [subPlan $bq $refs $ctx]
            set code "\[::mkitsql::rt::insub $id [lindex $a 0] \$r0 \$outer\]"
            if {$neg} { set code "\[::mkitsql::rt::not $code\]" }
            return [list $code bool]
        }
        exists {
            lassign $node _ bq refs
            set id [subPlan $bq $refs $ctx]
            return [list "\[::mkitsql::rt::exists $id \$r0 \$outer\]" bool]
        }
        sub {
            lassign $node _ bq refs ty
            set id [subPlan $bq $refs $ctx]
            return [list "\[::mkitsql::rt::scalar $id \$r0 \$outer\]" $ty]
        }
        case { return [cgCase $node $ctx] }
        cast { return [cgCast $node $ctx] }
        func { return [cgFunc $node $ctx] }
    }
    error "cg: unknown node [lindex $node 0]"
}

proc ::mkitsql::ctxPos {ctx level src name} {
    if {[dict exists $ctx dry]} { return 0 }
    set maps [dict get $ctx maps]
    set m [lindex $maps $level]
    set k $src,[string tolower $name]
    if {![dict exists $m $k]} { error "internal: unresolved column $k (level $level)" }
    return [dict get $m $k]
}

# Compile a bound subquery appearing inside an expression.  Returns its plan id.
proc ::mkitsql::subPlan {bq refs ctx} {
    variable planCorr
    if {[dict exists $ctx dry]} { return 0 }
    set id [compileQuery $bq [dict get $ctx maps]]
    set planCorr($id) [expr {[llength $refs] > 0}]
    return $id
}

proc ::mkitsql::cmpKind {ta tb} {
    set na [isNumType $ta] ; set nb [isNumType $tb]
    if {$na && $nb} { return n }
    if {($ta eq "null") || ($tb eq "null")} { return n }
    if {!$na && !$nb} { return s }
    return m
}

proc ::mkitsql::cgBin {node ctx} {
    lassign $node _ op a b
    switch -- $op {
        and - or {
            set wa [asBool [cg $a $ctx] [string toupper $op]]
            set wb [asBool [cg $b $ctx] [string toupper $op]]
            variable cxCount
            set t t[incr cxCount]
            if {$op eq "and"} {
                return [list "\[if {\[set $t $wa\] eq \"0\"} {set _ 0} else {::mkitsql::rt::and2 \$$t $wb}\]" bool]
            }
            return [list "\[if {\[set $t $wa\] eq \"1\"} {set _ 1} else {::mkitsql::rt::or2 \$$t $wb}\]" bool]
        }
        || {
            set wa [lindex [cg $a $ctx] 0] ; set wb [lindex [cg $b $ctx] 0]
            return [list "\[::mkitsql::rt::concat $wa $wb\]" text]
        }
        = - <> - < - <= - > - >= {
            set ca [cg $a $ctx] ; set cb [cg $b $ctx]
            set kind [cmpKind [lindex $ca 1] [lindex $cb 1]]
            set nm [dict get {= eq <> ne < lt <= le > gt >= ge} $op]
            return [list "\[::mkitsql::rt::${nm}_$kind [lindex $ca 0] [lindex $cb 0]\]" bool]
        }
        + - - - * - / - % {
            set ca [asNum [cg $a $ctx]] ; set cb [asNum [cg $b $ctx]]
            lassign $ca wa ta ; lassign $cb wb tb
            set isint [expr {$ta in {int bool} && $tb in {int bool}}]
            set res [expr {$isint ? "int" : "real"}]
            if {$ta eq "null" && $tb eq "null"} { set res int }
            switch -- $op {
                +  { set fn add }
                -  { set fn sub }
                *  { set fn mul }
                /  { set fn [expr {$isint ? "idiv" : "rdiv"}] }
                %  { set fn [expr {$isint ? "imod" : "rmod"}] }
            }
            return [list "\[::mkitsql::rt::$fn $wa $wb\]" $res]
        }
    }
    error "cgBin: $op"
}

proc ::mkitsql::cgIn {node ctx} {
    variable N
    lassign $node _ e items neg
    set ca [cg $e $ctx]
    lassign $ca wa ta
    set allLit 1
    foreach it $items { if {[lindex $it 0] ne "lit"} { set allLit 0 } }
    if {$allLit} {
        set vals {} ; set hasNull 0 ; set kind s
        set anyText 0 ; set anyNum 0
        foreach it $items {
            lassign $it _ ty v
            if {$ty eq "null"} { set hasNull 1 ; continue }
            lappend vals $v
            if {[isNumType $ty]} { set anyNum 1 } else { set anyText 1 }
        }
        if {[isNumType $ta] && !$anyText} { set kind n }
        if {$kind eq "n" || ([isNumType $ta] == 0 && !$anyNum)} {
            set code "\[::mkitsql::rt::inlist $wa [list $vals] $kind $hasNull\]"
            if {$neg} { set code "\[::mkitsql::rt::not $code\]" }
            return [list $code bool]
        }
    }
    # general case: OR of equalities
    set expr {}
    foreach it $items {
        set eqn [list bin = $e $it]
        if {$expr eq ""} { set expr $eqn } else { set expr [list bin or $expr $eqn] }
    }
    if {$neg} { set expr [list un not $expr] }
    return [cg $expr $ctx]
}

proc ::mkitsql::cgCase {node ctx} {
    lassign $node _ operand whens else
    set resType null
    set conds {} ; set results {}
    foreach w $whens {
        lassign $w c r
        if {$operand ne ""} { set c [list bin = $operand $c] }
        lappend conds [asBool [cg $c $ctx] WHEN]
        set cr [cg $r $ctx]
        lappend results [lindex $cr 0]
        set resType [unify $resType [lindex $cr 1]]
    }
    set ce [cg $else $ctx]
    set resType [unify $resType [lindex $ce 1]]
    set code [lindex $ce 0]
    set code "set _ $code"
    for {set i [expr {[llength $conds] - 1}]} {$i >= 0} {incr i -1} {
        set code "if {\[string equal [lindex $conds $i] 1\]} {set _ [lindex $results $i]} else {$code}"
    }
    return [list "\[$code\]" $resType]
}

proc ::mkitsql::cgCast {node ctx} {
    lassign $node _ e ty
    lassign [sqlType $ty] letter st kind
    set ca [cg $e $ctx]
    set w [lindex $ca 0]
    return [list "\[::mkitsql::rt::cast_$kind $w\]" $st]
}

# name -> {min max rettype} ; rettype: a type name, argN (type of arg N), num0
# (arg 0 if numeric else real), unify
proc ::mkitsql::funcTable {} {
    variable FT
    if {[info exists FT]} { return $FT }
    set FT {
        ABS {1 1 num0}      SIGN {1 1 int}     CEIL {1 1 num0}    CEILING {1 1 num0}
        FLOOR {1 1 num0}    ROUND {1 2 num0}   TRUNC {1 2 num0}   TRUNCATE {1 2 num0}
        SQRT {1 1 real}     POWER {2 2 real}   POW {2 2 real}     EXP {1 1 real}
        LN {1 1 real}       LOG10 {1 1 real}   SIN {1 1 real}     COS {1 1 real}
        TAN {1 1 real}      ASIN {1 1 real}    ACOS {1 1 real}    ATAN {1 1 real}
        ATAN2 {2 2 real}    DEGREES {1 1 real} RADIANS {1 1 real} PI {0 0 real}
        RANDOM {0 0 real}   MOD {2 2 unify}
        LENGTH {1 1 int}    CHAR_LENGTH {1 1 int} CHARACTER_LENGTH {1 1 int} OCTET_LENGTH {1 1 int}
        UPPER {1 1 text}    LOWER {1 1 text}   INITCAP {1 1 text}  TRIM_ {3 3 text}
        TRIM {1 2 text}     LTRIM {1 2 text}   RTRIM {1 2 text}   REPLACE {3 3 text}
        SUBSTR {2 3 text}   SUBSTRING {2 3 text} LEFT {2 2 text}  RIGHT {2 2 text}
        POSITION {2 2 int}  INSTR {2 2 int}    REPEAT {2 2 text}  REVERSE {1 1 text}
        LPAD {2 3 text}     RPAD {2 3 text}    ASCII {1 1 int}    CHR {1 1 text}
        CONCAT {1 -1 text}  CONCAT_WS {2 -1 text}
        COALESCE {1 -1 unify} IFNULL {2 2 unify} NVL {2 2 unify} NULLIF {2 2 arg0}
        GREATEST {1 -1 unify} LEAST {1 -1 unify}
        CURRENT_DATE {0 0 text} CURRENT_TIME {0 0 text} CURRENT_TIMESTAMP {0 0 text}
        LOCALTIME {0 0 text} LOCALTIMESTAMP {0 0 text} NOW {0 0 text}
        EXTRACT {2 2 num0}  ROWID_ {1 1 int}
    }
    return $FT
}

# Function names for editor highlighting / completion (internal helpers excluded).
set ::mkitsql::functions {}
foreach {k v} [::mkitsql::funcTable] {
    if {![string match *_ $k]} { lappend ::mkitsql::functions $k }
}
set ::mkitsql::functions [lsort $::mkitsql::functions]

proc ::mkitsql::cgFunc {node ctx} {
    variable aggs
    variable N
    lassign $node _ name distinct args
    if {[lsearch -exact $aggs $name] >= 0} {
        fail "Aggregate function ${name}() is not allowed here"
    }
    set ft [funcTable]
    if {![dict exists $ft $name]} { fail "Unknown function ${name}()" }
    lassign [dict get $ft $name] mn mx rt
    set n [llength $args]
    if {$n < $mn || ($mx >= 0 && $n > $mx)} {
        fail "Function ${name}() takes [expr {$mn == $mx ? $mn : ($mx < 0 ? "at least $mn" : "$mn to $mx")}] argument[expr {$mx == 1 ? {} : {s}}], not $n"
    }
    set cargs {}
    foreach a $args { lappend cargs [cg $a $ctx] }
    set words {} ; set types {}
    foreach c $cargs { lappend words [lindex $c 0] ; lappend types [lindex $c 1] }

    # ---- result type
    switch -- $rt {
        num0 {
            set t0 [lindex $types 0]
            set rtype [expr {$t0 in {int bool} ? "int" : "real"}]
            if {$name in {ROUND TRUNC TRUNCATE FLOOR CEIL CEILING ABS} && $t0 eq "null"} { set rtype int }
        }
        unify { set rtype null ; foreach t $types { set rtype [unify $rtype $t] } }
        arg0 { set rtype [lindex $types 0] }
        default { set rtype $rt }
    }

    # ---- special forms
    switch -- $name {
        COALESCE - IFNULL - NVL {
            set code "set _ $N"
            for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
                variable cxCount
                set t t[incr cxCount]
                set code "if {\[::mkitsql::rt::notnull \[set $t [lindex $words $i]\]\]} {set _ \$$t} else {$code}"
            }
            return [list "\[$code\]" $rtype]
        }
        NULLIF {
            set kind [cmpKind [lindex $types 0] [lindex $types 1]]
            return [list "\[::mkitsql::rt::fn_NULLIF [lindex $words 0] [lindex $words 1] ::mkitsql::rt::eq_$kind\]" $rtype]
        }
        GREATEST - LEAST {
            set kind [expr {[isNumType $rtype] ? "n" : "s"}]
            return [list "\[::mkitsql::rt::fn_$name $kind [join $words { }]\]" $rtype]
        }
        MOD {
            lassign [asNum [lindex $cargs 0]] wa ta ; lassign [asNum [lindex $cargs 1]] wb tb
            set isint [expr {$ta in {int bool} && $tb in {int bool}}]
            return [list "\[::mkitsql::rt::[expr {$isint ? {imod} : {rmod}}] $wa $wb\]" [expr {$isint ? "int" : "real"}]]
        }
        NOW { set name CURRENT_TIMESTAMP }
        LOCALTIME { set name CURRENT_TIME }
        LOCALTIMESTAMP { set name CURRENT_TIMESTAMP }
        CEILING { set name CEIL }
        TRUNCATE { set name TRUNC }
        POW { set name POWER }
        SUBSTRING { set name SUBSTR }
        CHAR_LENGTH - CHARACTER_LENGTH { set name LENGTH }
        INSTR { set name POSITION ; set words [list [lindex $words 1] [lindex $words 0]] }
        TRIM { set name [expr {$n == 2 ? "TRIM_" : "TRIM_"}]
               set words [list both [expr {$n == 2 ? [lindex $words 1] : [list { }]}] [lindex $words 0]] }
    }
    # numeric functions: coerce text arguments
    if {$name in {ABS SIGN CEIL FLOOR ROUND TRUNC SQRT POWER EXP LN LOG10 SIN COS TAN ASIN ACOS ATAN ATAN2 DEGREES RADIANS CHR LEFT RIGHT REPEAT LPAD RPAD}} {
        set i 0 ; set nw {}
        foreach c $cargs w $words {
            # LEFT/RIGHT/REPEAT/LPAD/RPAD: only the numeric arguments are coerced
            set coerce [expr {$name in {LEFT RIGHT REPEAT LPAD RPAD} ? ($i == 1) : 1}]
            if {$name in {LPAD RPAD} && $i == 2} { set coerce 0 }
            if {$coerce && [lindex $c 1] eq "text"} { set w "\[::mkitsql::rt::num $w\]" }
            lappend nw $w ; incr i
        }
        set words $nw
    }
    return [list "\[::mkitsql::rt::fn_$name [join $words { }]\]" $rtype]
}

# ============================================================================
#  Turning a word into a proc
# ============================================================================
# Compile `node` (a bound expression) into a proc taking {r0 outer}.
# Returns {procName type}.
proc ::mkitsql::compileExpr {node ctx} {
    variable cxCount
    lassign [cg $node $ctx] w t
    set name ::mkitsql::cx::p[incr cxCount]
    proc $name {r0 outer} "return $w"
    return [list $name $t]
}
# Compile a condition (WHERE / HAVING / ON): must be boolean or numeric.
proc ::mkitsql::compileCond {node ctx} {
    variable cxCount
    set wt [cg $node $ctx]
    if {[lindex $wt 1] eq "text" || [lindex $wt 1] eq "blob"} {
        fail "A condition (WHERE, HAVING, ON) must be true/false or a number, not [lindex $wt 1]"
    }
    set w [asBool $wt condition]
    set name ::mkitsql::cx::p[incr cxCount]
    proc $name {r0 outer} "return $w"
    return [list $name bool]
}
# Compile a list of expressions into one proc returning a list of their values.
proc ::mkitsql::compileList {nodes ctx} {
    variable cxCount
    set words {} ; set types {}
    foreach n $nodes {
        lassign [cg $n $ctx] w t
        lappend words $w ; lappend types $t
    }
    set name ::mkitsql::cx::p[incr cxCount]
    proc $name {r0 outer} "list [join $words { }]"
    return [list $name $types]
}
