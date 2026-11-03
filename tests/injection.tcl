# Code-injection and quoting test.  The engine turns SQL into Tcl code, so a string literal,
# parameter or identifier must NEVER be able to run as code or change a result.
#   tclsh tests/injection.tcl        (MKIT_MK4TCL as for the other tests)
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/vendor/store.tcl
source [file join [file dirname $here] mkitsql mkitsql.tcl]
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_inj_[pid].mk
file delete $f
set db [store::openFile $f -create]
set ::pwned 0
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$::pwned} { incr fail ; puts "!!! CODE EXECUTED during $name" ; set ::pwned 0 }
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string map {\n \\n} $got]\n   want: [string map {\n \\n} $want]" }
}
proc run {sql {p {}}} { mkitsql::run $sql $::db $p }
proc rows {sql {p {}}} { dict get [run $sql $p] rows }
proc lmap_ {l spec} { lassign $spec v b ; set o {} ; foreach item $l { lappend o [apply [list $v $b] $item] } ; return $o }
proc lit {s} { return "'[string map {' ''} $s]'" }

set nasty [list \
    {[set ::pwned 1]} {$::pwned} {\[set ::pwned 1\]} "\}\[set ::pwned 1\]\{" "\"; set ::pwned 1; \"" \
    "x\\" "\\" "\{" "\}" "\{\}" "\{\{" "\}\}" "a b" "line1\nline2" "tab\there" {[exit 7]} {A} {\x41} {$\{x\}} \
    {%} {_} {;} {;;} "\[" "\]" "\"" {""} {'} "\$x(1)" {$::env(HOME)} "\\\n" "\{\\" "set ::pwned 1" \
    "a\0b" {\0} "[format %c 233][format %c 9731]" {[list} {]]} {#} {# comment} "if \{1\} \{set ::pwned 1\}" {}]

foreach s $nasty {
    set L [lit $s]
    set tag "literal <[string range [string map {\n \\n} $s] 0 20]>"
    check "$tag select"      [lindex [rows "SELECT $L"] 0 0] $s
    check "$tag case"        [lindex [rows "SELECT CASE WHEN 1 = 1 THEN $L ELSE 'x' END"] 0 0] $s
    check "$tag case2"       [lindex [rows "SELECT CASE WHEN 1 = 0 THEN 'x' WHEN $L = $L THEN $L END"] 0 0] $s
    check "$tag coalesce"    [lindex [rows "SELECT COALESCE(NULL, $L), NULLIF($L, 'zzz')"] 0 0] $s
    check "$tag concat"      [lindex [rows "SELECT $L || $L"] 0 0] $s$s
    check "$tag and/or"      [lindex [rows "SELECT CASE WHEN $L = $L AND ($L <> 'q' OR $L = 'z') THEN 1 ELSE 0 END"] 0 0] 1
    check "$tag in"          [lindex [rows "SELECT CASE WHEN $L IN ($L, 'q') THEN 1 ELSE 0 END, CASE WHEN $L NOT IN ('q', 'r') THEN 1 ELSE 0 END"] 0] {1 1}
    check "$tag upper"       [lindex [rows "SELECT UPPER($L)"] 0 0] [string toupper $s]
    check "$tag length"      [lindex [rows "SELECT LENGTH($L)"] 0 0] [string length $s]
    check "$tag like self"   [lindex [rows "SELECT CASE WHEN $L LIKE $L OR 1 = 1 THEN 1 END"] 0 0] 1
    check "$tag like pat"    [lindex [rows "SELECT CASE WHEN 'abc' LIKE $L THEN 1 ELSE 0 END"] 0 0] [expr {$s eq "abc" || $s eq "%" || $s eq "a%" ? 1 : [expr {[regexp {^[a-c_%]*$} $s] && [regexp "^[string map {% .* _ .} $s]\$" abc] ? 1 : 0}]}]
    check "$tag values"      [lindex [rows "SELECT x FROM (VALUES ($L)) t(x)"] 0 0] $s
    check "$tag cast"        [lindex [rows "SELECT CAST($L AS VARCHAR)"] 0 0] $s
    check "$tag substr"      [lindex [rows "SELECT SUBSTR($L, 1)"] 0 0] $s
    check "$tag replace"     [lindex [rows "SELECT REPLACE($L, 'zzzz', 'y')"] 0 0] $s
    check "$tag param"       [lindex [rows "SELECT ?" [list $s]] 0 0] $s
    check "$tag param cmp"   [lindex [rows "SELECT CASE WHEN ? = $L THEN 1 ELSE 0 END" [list $s]] 0 0] 1
    check "$tag named param" [lindex [rows "SELECT :v" [list v $s]] 0 0] $s
    # as an identifier / alias
    if {$s ne ""} {
        set Q "\"[string map {\" \"\"} $s]\""
        check "$tag alias"     [dict get [run "SELECT 1 AS $Q"] cols] [list $s]
        check "$tag alias ref" [lindex [rows "SELECT $Q FROM (SELECT 7 AS $Q) t"] 0 0] 7
        check "$tag alias ord" [lindex [rows "SELECT $Q FROM (SELECT 7 AS $Q) t ORDER BY $Q"] 0 0] 7
        check "$tag tbl alias" [lindex [rows "SELECT $Q.x FROM (SELECT 7 AS x) AS $Q"] 0 0] 7
    }
}

# stored data round trip: literal into a table, then read back through scan/filter/group/order/window/join
run "CREATE TABLE inj (id INT, c VARCHAR(100))"
set i 0
foreach s $nasty { incr i ; run "INSERT INTO inj VALUES ($i, [lit $s])" }
set i 0
foreach s $nasty {
    incr i ; set L [lit $s]
    set tag "stored <[string range [string map {\n \\n} $s] 0 20]>"
    check "$tag where"   [rows "SELECT c FROM inj WHERE id = $i"] [list [list $s]]
    check "$tag eq"      [lindex [lsort -integer [lmap_ [rows "SELECT id FROM inj WHERE c = $L"] {r {lindex $r 0}}]] 0] [expr {[lsearch -exact $nasty $s] + 1}]
    check "$tag group"   [expr {[lsearch -exact [lmap_ [rows "SELECT c FROM inj GROUP BY c"] {r {lindex $r 0}}] $s] >= 0}] 1
    check "$tag order"   [expr {[lsearch -exact [lmap_ [rows "SELECT c FROM inj ORDER BY c"] {r {lindex $r 0}}] $s] >= 0}] 1
    check "$tag window"  [lindex [rows "SELECT COUNT(*) OVER (PARTITION BY c) FROM inj WHERE id = $i"] 0 0] [llength [lsearch -all -exact $nasty $s]]
    check "$tag join"    [expr {[llength [rows "SELECT a.id FROM inj a JOIN inj b ON a.c = b.c WHERE a.id = $i"]] >= 1}] 1
    check "$tag update"  [lindex [rows "SELECT c || '!' FROM inj WHERE id = $i"] 0 0] "$s!"
}

# whole-statement attacks that must stay inert
foreach sql [list \
    "SELECT '\]; set ::pwned 1; \['" \
    "SELECT 1 /* \[set ::pwned 1\] */" \
    "SELECT 1 -- \[set ::pwned 1\]" \
    "SELECT \"\]\[set ::pwned 1\]\" FROM (SELECT 1 AS \"\]\[set ::pwned 1\]\") t"] {
    catch {run $sql}
    check "inert: [string range $sql 0 40]" $::pwned 0
}
store::closeFile $db ; file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
