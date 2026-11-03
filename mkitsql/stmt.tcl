# stmt.tcl -- statement execution for mkit-sql: SELECT result shaping, INSERT,
# UPDATE, DELETE, CREATE / DROP / ALTER TABLE, transactions and the small
# administrative statements MK Studio relies on (USE, SHOW, DESCRIBE).
#
# execStatement ast ?defaultDb? ?params?  returns one of
#   {kind rowset cols .. types .. rows .. rowids .. source .. drill .. truncated 0|1 editable 0|1}
#   {kind message text .. affected N ?use db?}
#
# Writes are all-or-nothing per statement: every value is validated and
# converted *before* anything is written to Metakit.

namespace eval ::mkitsql {
    variable nullText "NULL"     ;# how NULL is shown in result grids
    variable autocommit 0        ;# 1 = commit after every successful write statement
    variable intMin -2147483648
    variable intMax 2147483647
}

# ============================================================================
#  Entry point
# ============================================================================
proc ::mkitsql::resetStatement {} {
    variable plans ; variable subCache ; variable planCorr ; variable needed
    variable scopes ; variable ctes ; variable refLog ; variable fromSoFar ; variable lookupIdx
    foreach p [info procs ::mkitsql::cx::*] { rename $p {} }
    array unset lookupIdx ; array set lookupIdx {}
    array unset plans ; array unset subCache ; array unset planCorr ; array unset needed
    array set plans {} ; array set subCache {} ; array set planCorr {} ; array set needed {}
    set scopes {} ; set ctes {} ; set refLog {} ; set fromSoFar {}
}

proc ::mkitsql::execStatement {ast {db ""} {plist {}}} {
    variable defaultDb ; variable cancel ; variable capRows
    set savedParams $plist
    resetStatement
    set defaultDb $db
    set cancel 0 ; set capRows 0
    # positional parameters are given as a list, named ones as a dict
    set pd [dict create]
    if {[llength $savedParams] && [llength $savedParams] % 2 == 0 && [paramsLookNamed $savedParams]} {
        set pd $savedParams
    } else {
        set i 0
        foreach v $savedParams { dict set pd [incr i] $v }
    }
    set ::mkitsql::params $pd
    switch -- [lindex $ast 0] {
        select   { return [execSelect [lindex $ast 1]] }
        insert   { return [afterWrite [execInsert [lindex $ast 1]]] }
        update   { return [afterWrite [execUpdate [lindex $ast 1]]] }
        delete   { return [afterWrite [execDelete [lindex $ast 1]]] }
        create   { return [afterWrite [execCreate [lindex $ast 1]]] }
        drop     { return [afterWrite [execDrop [lindex $ast 1]]] }
        alter    { return [afterWrite [execAlter [lindex $ast 1]]] }
        begin    { return [msg "Transaction started.  Changes stay in memory until COMMIT." 0] }
        commit   { return [execTxn commit [lindex $ast 1]] }
        rollback { return [execTxn rollback [lindex $ast 1]] }
        use {
            set d [findTag [lindex $ast 1]]
            if {$d eq ""} { fail "Unknown database '[lindex $ast 1]'. Open databases: [join [::store::tags] {, }]" }
            return [dict create kind message text "Now using database '$d'." use $d affected -1]
        }
        showdbs   { return [execShowDbs] }
        showtables { return [execShowTables [lindex $ast 1]] }
        describe  { return [execDescribe [lindex $ast 1]] }
    }
    error "execStatement: unknown statement [lindex $ast 0]"
}

# {a 1 b 2} (even length, keys that are not plain integers) = named parameters
proc ::mkitsql::paramsLookNamed {l} {
    foreach {k v} $l { if {[string is integer -strict $k] && $k > 0 && $k <= [expr {[llength $l]}]} { return 0 } }
    return 1
}

proc ::mkitsql::msg {text {affected -1}} {
    dict create kind message text $text affected $affected
}

proc ::mkitsql::afterWrite {res} {
    variable autocommit
    if {$autocommit && [dict exists $res tag]} {
        ::store::commit [dict get $res tag]
        dict set res text "[dict get $res text]  (committed)"
    }
    return $res
}

proc ::mkitsql::plural {n word} { return "$n $word[expr {$n == 1 ? {} : {s}}]" }

# ============================================================================
#  SELECT
# ============================================================================
proc ::mkitsql::execSelect {q} {
    variable maxRows ; variable capRows ; variable nullText ; variable plans ; variable N
    set bq [bindQuery $q]
    set id [compileQuery $bq {}]
    set p $plans($id)
    set kind [dict get $p kind]
    if {$kind eq "select" && [dict get $p stoppable] && [dict get $p limit] eq ""} {
        set capRows [expr {$maxRows + 1}]
    }
    set ids {}
    if {$kind eq "select"} {
        lassign [runSelect $p {}] rows ids
    } else {
        set rows [runPlan $id {}]
    }
    set capRows 0
    set truncated 0
    if {[llength $rows] > $maxRows} {
        set rows [lrange $rows 0 [expr {$maxRows - 1}]]
        set ids [lrange $ids 0 [expr {$maxRows - 1}]]
        set truncated 1
    }
    set names [dict get $p names]
    set plain [expr {$kind eq "select" && [dict get $p plain]}]
    # column types for the grid
    set types {} ; set drill [dict create]
    set ci 0
    foreach t [dict get $p types] l [dict get $p letters] d [dict get $p drill] {
        if {$l ne ""} { lappend types $l } else { lappend types [letterOfType $t] }
        if {$plain && $d ne "0"} { dict set drill $ci $d }
        incr ci
    }
    # intervals are held in an internal form; show them readably
    set ivCols {}
    set ci 0
    foreach t [dict get $p types] { if {$t eq "interval"} { lappend ivCols $ci } ; incr ci }
    if {[llength $ivCols]} {
        set rows2 {}
        foreach r $rows {
            foreach i $ivCols { set v [lindex $r $i] ; if {$v ne $N} { lset r $i [ivFormat $v] } }
            lappend rows2 $r
        }
        set rows $rows2
    }
    # display: NULL text, "\u25B8 N rows" for subview counts
    set outRows {}
    set width [llength $names]
    set hasDrill [dict size $drill]
    foreach r $rows {
        if {[lsearch -exact $r $N] >= 0} {
            set r2 {}
            foreach v $r { if {$v eq $N} { lappend r2 $nullText } else { lappend r2 $v } }
            set r $r2
        }
        if {$hasDrill} {
            dict for {i sub} $drill {
                set n [lindex $r $i]
                lset r $i "\u25B8 $n row[expr {$n == 1 ? {} : {s}}]"
            }
        }
        lappend outRows $r
    }
    return [dict create kind rowset cols $names types $types rows $outRows rowids $ids \
        source [expr {$plain ? [dict get $p source] : ""}] drill $drill truncated $truncated editable $plain]
}

# ============================================================================
#  Targets and value conversion
# ============================================================================
# Resolve the target of INSERT / UPDATE / DELETE / ALTER.  Returns
# {tag view path layout label}.
proc ::mkitsql::resolveTarget {parts subs} {
    lassign [resolveTable $parts] tag view
    if {[::store::readonly $tag]} { fail "Database '$tag' is open read-only." }
    set path $tag.$view
    set layout [::store::layout $path]
    set label $view
    if {[llength $subs]} { lassign [walkSubs $path $layout $label $subs] path layout label }
    return [list $tag $view $path $layout $label]
}

proc ::mkitsql::findLayoutCol {layout name} {
    foreach c $layout { if {[string equal -nocase [lindex $c 0] $name]} { return $c } }
    return ""
}

proc ::mkitsql::letterWords {l} {
    switch -- $l {
        S { return "text" } I { return "whole numbers (INTEGER)" } L { return "whole numbers (BIGINT)" }
        F - D { return "numbers" } B { return "binary data" }
    }
    return $l
}

# Convert a computed value for storage in a column of type `letter`.
proc ::mkitsql::coerceValue {col letter v} {
    variable N ; variable intMin ; variable intMax
    if {$v eq $N} { return [expr {$letter in {I L F D} ? 0 : ""}] }
    switch -- $letter {
        I - L {
            set x [string trim $v]
            if {[regexp {^[-+]?\d+$} $x]} {
                regsub {^([-+]?)0+(?=\d)} $x {\1} x
                set x [expr {$x + 0}]
            } elseif {[regexp {^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$} $x] && $x == int($x)} {
                set x [expr {int($x)}]
            } else {
                fail "Column '$col' holds [letterWords $letter], but '[string range $v 0 40]' is not a whole number"
            }
            if {$letter eq "I" && ($x < $intMin || $x > $intMax)} {
                fail "Value $x is out of range for 32-bit INTEGER column '$col' (use BIGINT for larger numbers)"
            }
            if {$letter eq "L" && !($x >= -9223372036854775808 && $x <= 9223372036854775807)} {
                fail "Value $x is out of range for BIGINT column '$col'"
            }
            return $x
        }
        F - D {
            set x [string trim $v]
            if {![regexp {^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$} $x]} {
                fail "Column '$col' holds numbers, but '[string range $v 0 40]' is not one"
            }
            regsub {^([-+]?)0+(?=\d)} $x {\1} x
            return $x
        }
    }
    # an interval stored into a text column keeps its readable form
    if {[string match ivl:* $v]} { return [ivFormat $v] }
    return $v
}

# ============================================================================
#  INSERT
# ============================================================================
proc ::mkitsql::execInsert {st} {
    variable plans ; variable N
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set cols [dict get $st cols]
    if {![llength $cols]} {
        set cols {}
        foreach c $layout { if {[lindex $c 1] ne "V"} { lappend cols [lindex $c 0] } }
    }
    set targets {}                 ;# {name letter}
    set seen {}
    foreach c $cols {
        set lc [findLayoutCol $layout $c]
        if {$lc eq ""} { fail "Unknown column '$c' in '$label'.  Available: [join [lmap2 $layout {x {lindex $x 0}}] {, }]" }
        if {[lindex $lc 1] eq "V"} { fail "'$c' is a subview; insert into it with  INSERT INTO $label\[row\].$c ..." }
        if {[lsearch -exact $seen [string tolower $c]] >= 0} { fail "Column '$c' is listed twice" }
        lappend seen [string tolower $c]
        lappend targets [list [lindex $lc 0] [lindex $lc 1]]
    }
    set src [dict get $st source]
    if {[dict get $src type] eq "defaults"} {
        set rows [list [lrepeat [llength $targets] $N]]
        if {[llength $cols] == 0} { set rows [list {}] }
    } else {
        set bq [bindQuery $src]
        set id [compileQuery $bq {}]
        set rows [runPlan $id {}]
        set w [llength [dict get $bq outNames]]
        if {$w != [llength $targets]} {
            fail "INSERT has [llength $targets] target column[expr {[llength $targets] == 1 ? {} : {s}}] but the source provides $w value[expr {$w == 1 ? {} : {s}}]"
        }
    }
    # validate and convert everything first
    set props {} ; foreach t $targets { lappend props [lindex $t 0] }
    set batch {}
    foreach r $rows {
        set vals {}
        foreach t $targets v $r { lappend vals [coerceValue [lindex $t 0] [lindex $t 1] $v] }
        lappend batch $vals
    }
    foreach vals $batch { ::store::appendRow $path $props $vals }
    set n [llength $batch]
    return [dict create kind message text "[plural $n row] inserted into '$label'." affected $n tag $tag]
}

# tiny map helper (Tcl 8.5 has no lmap)
proc ::mkitsql::lmap2 {list spec} {
    lassign $spec var body
    set out {}
    foreach item $list { lappend out [apply [list $var $body] $item] }
    return $out
}

# ============================================================================
#  UPDATE / DELETE  (run as a synthetic SELECT that also returns _rowid)
# ============================================================================
proc ::mkitsql::syntheticSelect {st items} {
    set sel [dict create type select distinct 0 items $items \
        from [list table [dict get $st parts] [dict get $st subs] [dict get $st alias]] \
        where [dict get $st where] group {} having {}]
    return [dict create type query with {} body $sel order {} limit {} offset {}]
}

proc ::mkitsql::execUpdate {st} {
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set sets [dict get $st sets]
    set items {} ; set targets {} ; set seen {}
    foreach s $sets {
        lassign $s c e
        set lc [findLayoutCol $layout $c]
        if {$lc eq ""} { fail "Unknown column '$c' in '$label'.  Available: [join [lmap2 $layout {x {lindex $x 0}}] {, }]" }
        if {[lindex $lc 1] eq "V"} { fail "'$c' is a subview and cannot be assigned" }
        if {[lsearch -exact $seen [string tolower $c]] >= 0} { fail "Column '$c' is assigned twice" }
        lappend seen [string tolower $c]
        lappend targets [list [lindex $lc 0] [lindex $lc 1]]
        lappend items [list $e {} $c]
    }
    lappend items [list {col {} _rowid} {} _rowid]
    set bq [bindQuery [syntheticSelect $st $items]]
    set id [compileQuery $bq {}]
    set rows [runPlan $id {}]
    # convert all new values before touching the file
    set plan {}
    foreach r $rows {
        set rid [lindex $r end]
        set vals {}
        set i 0
        foreach t $targets {
            lappend vals [coerceValue [lindex $t 0] [lindex $t 1] [lindex $r $i]]
            incr i
        }
        lappend plan [list $rid $vals]
    }
    foreach pr $plan {
        lassign $pr rid vals
        foreach t $targets v $vals { ::store::setCell $path $rid [lindex $t 0] $v }
    }
    set n [llength $plan]
    return [dict create kind message text "[plural $n row] updated in '$label'." affected $n tag $tag]
}

proc ::mkitsql::execDelete {st} {
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    set items [list [list {col {} _rowid} {} _rowid]]
    set bq [bindQuery [syntheticSelect $st $items]]
    set id [compileQuery $bq {}]
    set rows [runPlan $id {}]
    set idx {}
    foreach r $rows { lappend idx [lindex $r 0] }
    if {[llength $idx]} { ::store::deleteRows $path $idx }
    set n [llength $idx]
    return [dict create kind message text "[plural $n row] deleted from '$label'." affected $n tag $tag]
}

# ============================================================================
#  DDL
# ============================================================================
# Where does a new table go?  Returns {tag name}.
proc ::mkitsql::newTableName {parts} {
    variable defaultDb
    set tags [::store::tags]
    if {![llength $tags]} { fail "No database is open." }
    if {[llength $parts] == 2} {
        set tag [findTag [lindex $parts 0]]
        if {$tag eq ""} { fail "Unknown database '[lindex $parts 0]'. Open databases: [join $tags {, }]" }
        return [list $tag [lindex $parts 1]]
    }
    if {$defaultDb ne "" && [findTag $defaultDb] ne ""} { return [list [findTag $defaultDb] [lindex $parts 0]] }
    if {[llength $tags] == 1} { return [list [lindex $tags 0] [lindex $parts 0]] }
    fail "Several databases are open ([join $tags {, }]).  Qualify the name, e.g. [lindex $tags 0].[lindex $parts 0]"
}

# Metakit names live in layout strings, so they cannot contain spaces or punctuation.
proc ::mkitsql::checkName {name what} {
    if {![regexp {^[[:alpha:]_][[:alnum:]_]*$} $name]} {
        fail "$what name '$name' is not allowed: Metakit names may only contain letters, digits and underscores, and cannot start with a digit"
    }
}

# parser column definitions -> Metakit layout
proc ::mkitsql::defsToLayout {defs} {
    set layout {} ; set seen {}
    foreach d $defs {
        lassign $d name ty sub
        checkName $name Column
        if {[lsearch -exact $seen [string tolower $name]] >= 0} { fail "Column '$name' is defined twice" }
        lappend seen [string tolower $name]
        if {$ty eq "subview"} {
            lappend layout [list $name V [defsToLayout $sub]]
        } elseif {$ty eq "interval"} {
            fail "INTERVAL columns are not supported; store the length as a number of seconds or as text"
        } else {
            lappend layout [list $name [lindex [sqlType $ty] 0] {}]
        }
    }
    return $layout
}

proc ::mkitsql::execCreate {st} {
    lassign [newTableName [dict get $st parts]] tag name
    if {[::store::readonly $tag]} { fail "Database '$tag' is open read-only." }
    checkName $name Table
    if {[findView $tag $name] ne ""} {
        if {[dict get $st ifnotexists]} { return [dict create kind message text "Table '$name' already exists in '$tag'; nothing to do." affected 0 tag $tag] }
        fail "Table '$name' already exists in '$tag'."
    }
    if {[dict exists $st query]} { return [createTableAs $tag $name [dict get $st query]] }
    ::store::createView $tag $name [defsToLayout [dict get $st cols]]
    return [dict create kind message text "Table '$name' created in '$tag'." affected 0 tag $tag]
}

# CREATE TABLE name AS <query>:  column types come from the query's static types.
proc ::mkitsql::createTableAs {tag name q} {
    variable plans ; variable N
    set bq [bindQuery $q]
    set id [compileQuery $bq {}]
    set rows [runPlan $id {}]
    set names [dict get $bq outNames] ; set types [dict get $bq outTypes]
    set layout {} ; set seen {} ; set i 0
    foreach n $names t $types {
        checkName $n Column
        if {[lsearch -exact $seen [string tolower $n]] >= 0} { fail "Column '$n' appears twice; give one an alias" }
        lappend seen [string tolower $n]
        switch -- $t {
            int - bool { set letter I
                foreach r $rows {
                    set v [lindex $r $i]
                    if {$v ne $N && ($v < $::mkitsql::intMin || $v > $::mkitsql::intMax)} { set letter L ; break }
                } }
            real { set letter D }
            blob { set letter B }
            default { set letter S }
        }
        lappend layout [list $n $letter {}]
        incr i
    }
    # convert everything before creating anything
    set batch {}
    foreach r $rows {
        set vals {} ; set j 0
        foreach v $r { lappend vals [coerceValue [lindex $names $j] [lindex $layout $j 1] $v] ; incr j }
        lappend batch $vals
    }
    ::store::createView $tag $name $layout
    foreach vals $batch { ::store::appendRow $tag.$name $names $vals }
    set n [llength $batch]
    return [dict create kind message text "Table '$name' created in '$tag' with [plural $n row]." affected $n tag $tag]
}

proc ::mkitsql::execDrop {st} {
    set parts [dict get $st parts]
    if {[dict get $st ifexists]} {
        if {[catch {resolveTable $parts} r]} {
            return [dict create kind message text "Table '[lindex $parts end]' does not exist; nothing to do." affected 0]
        }
    }
    lassign [resolveTable $parts] tag view
    if {[::store::readonly $tag]} { fail "Database '$tag' is open read-only." }
    ::store::dropView $tag $view
    return [dict create kind message text "Table '$view' dropped from '$tag'." affected 0 tag $tag]
}

proc ::mkitsql::execAlter {st} {
    lassign [resolveTarget [dict get $st parts] [dict get $st subs]] tag view path layout label
    lassign [dict get $st action] what a1 a2
    switch -- $what {
        add {
            lassign $a1 name ty sub
            if {[findLayoutCol $layout $name] ne ""} { fail "Column '$name' already exists in '$label'." }
            checkName $name Column
            set new [lindex [defsToLayout [list $a1]] 0]
            ::store::restructure $path [concat $layout [list $new]]
            set text "Column '$name' added to '$label'.  Existing rows get the default (0 or empty text)."
        }
        drop {
            set c [findLayoutCol $layout $a1]
            if {$c eq ""} { fail "Unknown column '$a1' in '$label'." }
            if {[llength $layout] == 1} { fail "A table must keep at least one column." }
            set new {}
            foreach x $layout { if {$x ne $c} { lappend new $x } }
            ::store::restructure $path $new
            set text "Column '[lindex $c 0]' dropped from '$label'."
        }
        rename {
            set c [findLayoutCol $layout $a1]
            if {$c eq ""} { fail "Unknown column '$a1' in '$label'." }
            if {[lindex $c 1] eq "V"} { fail "Renaming a subview column is not supported (Metakit would discard its rows)." }
            checkName $a2 Column
            if {[findLayoutCol $layout $a2] ne "" && ![string equal -nocase $a1 $a2]} { fail "Column '$a2' already exists in '$label'." }
            ::store::rebuildColumn $path [lindex $c 0] $a2 [lindex $c 1]
            set text "Column '[lindex $c 0]' renamed to '$a2'.  (Metakit moves a renamed column to the end of the table.)"
        }
        retype {
            set c [findLayoutCol $layout $a1]
            if {$c eq ""} { fail "Unknown column '$a1' in '$label'." }
            if {[lindex $c 1] eq "V"} { fail "A subview column cannot change type." }
            set letter [lindex [sqlType $a2] 0]
            ::store::rebuildColumn $path [lindex $c 0] [lindex $c 0] $letter
            set text "Column '[lindex $c 0]' changed to $a2.  (Metakit moves it to the end of the table.)"
        }
        renametable {
            if {[llength [dict get $st subs]]} { fail "Only a top-level table can be renamed." }
            checkName $a1 Table
            if {[findView $tag $a1] ne ""} { fail "Table '$a1' already exists in '$tag'." }
            # Metakit cannot rename a view: copy it (subviews included), then drop the original
            ::store::createView $tag $a1 $layout
            copyRows $path $tag.$a1 $layout
            ::store::dropView $tag $view
            set text "Table '$view' renamed to '$a1'."
        }
    }
    return [dict create kind message text $text affected 0 tag $tag]
}

# Copy every row (and, recursively, every subview) from one view to another
# that already has the same layout.
proc ::mkitsql::copyRows {src dst layout} {
    set props {} ; set subs {}
    foreach c $layout {
        if {[lindex $c 1] eq "V"} { lappend subs $c } else { lappend props [lindex $c 0] }
    }
    set n [::store::size $src]
    for {set first 0} {$first < $n} {incr first 1000} {
        set i $first
        foreach r [::store::rows $src $props $first 1000] {
            set j [::store::appendRow $dst $props $r]
            foreach sc $subs {
                set nm [lindex $sc 0]
                copyRows $src!$i.$nm $dst!$j.$nm [lindex $sc 2]
            }
            incr i
        }
    }
}

# ============================================================================
#  Transactions and administration
# ============================================================================
proc ::mkitsql::execTxn {what db} {
    variable defaultDb
    set tags [::store::tags]
    if {$db ne ""} {
        set t [findTag $db]
        if {$t eq ""} { fail "Unknown database '$db'. Open databases: [join $tags {, }]" }
        set targets [list $t]
    } else {
        set targets {}
        foreach t $tags { if {[::store::dirty $t] > 0} { lappend targets $t } }
        if {![llength $targets]} {
            return [msg "Nothing to $what: there are no pending changes." 0]
        }
    }
    set total 0
    foreach t $targets {
        if {$what eq "commit"} {
            if {[::store::readonly $t]} { fail "Database '$t' is open read-only." }
            set n [::store::dirty $t]
            ::store::commit $t
        } else {
            set n [::store::dirty $t]
            ::store::rollback $t
        }
        incr total $n
    }
    if {$what eq "commit"} {
        return [msg "Changes to [join $targets {, }] committed to disk." $total]
    }
    return [msg "Rolled back [plural $total {pending change}] in [join $targets {, }]." $total]
}

proc ::mkitsql::rowset {cols types rows} {
    return [dict create kind rowset cols $cols types $types rows $rows rowids {} source "" \
        drill [dict create] truncated 0 editable 0]
}

proc ::mkitsql::execShowDbs {} {
    set rows {}
    foreach t [::store::tags] {
        lappend rows [list $t [::store::path $t] [llength [::store::views $t]] \
            [expr {[::store::readonly $t] ? "read-only" : "read/write"}] [::store::dirty $t]]
    }
    return [rowset {database file tables mode pending_changes} {"" "" N "" N} $rows]
}

proc ::mkitsql::execShowTables {db} {
    set tags [::store::tags]
    if {$db ne ""} {
        set t [findTag $db]
        if {$t eq ""} { fail "Unknown database '$db'. Open databases: [join $tags {, }]" }
        set tags [list $t]
    }
    set rows {}
    foreach t $tags {
        foreach v [::store::views $t] {
            lappend rows [list $t $v [::store::size $t.$v] [llength [::store::layout $t.$v]]]
        }
    }
    return [rowset {database table rows columns} {"" "" N N} $rows]
}

proc ::mkitsql::execDescribe {st} {
    lassign [resolveTable [dict get $st parts]] tag view
    set path $tag.$view ; set layout [::store::layout $path]
    if {[llength [dict get $st subs]]} { lassign [walkSubs $path $layout $view [dict get $st subs]] path layout label }
    set rows {} ; set n 0
    foreach r [flattenLayout $layout "" 0] { lappend rows [linsert $r 0 [incr n]] }
    return [rowset {# column type kind code} {N "" "" "" ""} $rows]
}
proc ::mkitsql::flattenLayout {layout prefix depth} {
    set out {}
    foreach c $layout {
        lassign $c n l sub
        if {$l eq "V"} {
            lappend out [list $prefix$n TABLE subview V]
            set out [concat $out [flattenLayout $sub "$prefix$n." [expr {$depth + 1}]]]
        } else {
            lappend out [list $prefix$n [letterSqlName $l] column $l]
        }
    }
    return $out
}
