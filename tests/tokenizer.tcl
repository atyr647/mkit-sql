# The tokenizer (one capture-free regular expression, kind from the first character) must give exactly what the original one (eight capture
# groups) gave, on every text: documentation examples, the SQL of the test suites, and thousands of random and mutated texts.   tclsh tests/tokenizer.tcl [n]
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set n [expr {$argc > 0 ? [lindex $argv 0] : 20000}]
expr {srand(23)}
# the original, frozen here as the oracle
set oldRe {(--[^\n]*)|(/\*(?:[^*]|\*(?!/))*\*/)|('(?:[^']|'')*')|("(?:[^"]|"")*")|((?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)|([A-Za-z_][A-Za-z0-9_$]*)|(<>|!=|<=|>=|==|\|\||[-+*/%=<>(),;.\[\]!@?:])|(\S)}
proc oldTokenize {text} {
    global oldRe
    set out {}
    set kinds {comment comment string qident number ident op bad}
    foreach {all g1 g2 g3 g4 g5 g6 g7 g8} [regexp -all -inline -indices $oldRe $text] {
        lassign $all s e
        set k 0
        foreach g [list $g1 $g2 $g3 $g4 $g5 $g6 $g7 $g8] { if {[lindex $g 0] >= 0} break ; incr k }
        set kind [lindex $kinds $k]
        if {$kind eq "comment"} continue
        set raw [string range $text $s $e]
        switch -- $kind {
            string { set val [string map {'' '} [string range $raw 1 end-1]] }
            qident { set val [string map {\"\" \"} [string range $raw 1 end-1]] }
            default { set val $raw }
        }
        lappend out [list $kind $val $s [expr {$e - $s + 1}]]
    }
    return $out
}
set pass 0 ; set fail 0
# ::mkitsql::tokenRe is part of the interface to MK Studio (its editor colours text with the eight groups, in this order): it must stay as it was
if {$::mkitsql::tokenRe eq $oldRe && [llength [regexp -inline -indices $::mkitsql::tokenRe "x"]] == 9} { incr pass } else { incr fail ; puts "FAIL tokenRe changed" }
proc same {text} {
    global pass fail
    if {[oldTokenize $text] eq [mkitsql::tokenize $text]} { incr pass } else { incr fail ; if {$fail < 6} { puts "FAIL on <[string range $text 0 120]>" } }
}
# 1. texts from the repository: every quoted string in the test scripts that looks like SQL, and the documentation's code blocks
set corpus {}
foreach f [glob -directory $here *.tcl] {
    set h [open $f r] ; set txt [read $h] ; close $h
    foreach {all m} [regexp -all -inline {"((?:SELECT|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|WITH|MERGE|EXPLAIN)[^"\n]*)"} $txt] { lappend corpus $m }
}
set h [open $here/../docs/SQL.md r] ; set md [read $h] ; close $h
foreach {all m} [regexp -all -inline {```sql\n(.*?)```} $md] { lappend corpus $m }
foreach t $corpus { same $t }
puts "  ([llength $corpus] texts from the repository)"
# 2. edge texts
foreach t [list "" " " "'" "\"" "'abc" "\"abc" "'a''b'" "\"a\"\"b\"" "--" "-- x" "/*" "/* x" "/* x */" "a/*b*/c" "1." ".5" "." "1.5e+3" "1e" "e1" "1.e2" ".e2" "a.b" "a . b" "<>" "< >" "<=>" "!=" "!" "==" "|" "||" "|||" "x_1\$y" "\$a" "[format %c 233]" "caf[format %c 233] x" "[format %c 26085][format %c 26412]" "a\u0000b" "\t\n\r x" "- -" "--\n--" "'x'--y" "'x'/*y*/'z'" "1..2" "1.2.3" "--[format %c 1]" "@a ?b :c" "a:=b" "((()))" ";;;" "x;y"] { same $t }
# 3. random texts over an alphabet of the characters that matter, and mutations of corpus texts
set alpha [list a Z _ 1 9 . e E + - * / % = < > ! | ( ) , ";" ' \" " " "\n" "\t" : @ ? \[ \] \\ \$ [format %c 233] [format %c 26085] "--" "/*" "*/" "''" "\"\""]
for {set i 0} {$i < $n} {incr i} {
    set t ""
    for {set j 0} {$j < 1 + int(rand() * 24)} {incr j} { append t [lindex $alpha [expr {int(rand() * [llength $alpha])}]] }
    same $t
    if {[llength $corpus]} {
        set b [lindex $corpus [expr {int(rand() * [llength $corpus])}]]
        set p [expr {int(rand() * ([string length $b] + 1))}]
        same [string replace $b $p $p [lindex $alpha [expr {int(rand() * [llength $alpha])}]]]
    }
}
# 4. the parser's shortcut for a lone literal gives the same tree (or the same error) as the full precedence climb
proc parseBoth {text} {
    foreach fp {0 1} {
        set ::mkitsql::fastParse $fp
        array unset ::mkitsql::parseCache
        if {[catch {mkitsql::parseScript $text} r opts]} { set res($fp) [list ERR $r [dict get $opts -errorcode]] } else { set res($fp) [list OK $r] }
    }
    set ::mkitsql::fastParse 1
    return [expr {$res(0) eq $res(1)}]
}
set pp 0 ; set pf 0
foreach t $corpus { if {[parseBoth $t]} { incr pp } else { incr pf ; if {$pf < 6} { puts "PARSE DIFFERS on <[string range $t 0 120]>" } } }
foreach t {"SELECT 1" "SELECT 1, 2" "SELECT 1 + 2" "SELECT 'a' || 'b'" "SELECT 1 AS x" "VALUES (1, 'a'), (2, 'b')" "INSERT INTO t VALUES (1, 2.5, 'x', -3, NULL)" "SELECT 1 2" "SELECT 1,," "INSERT INTO t VALUES (1" "SELECT 'a' COLLATE NOCASE" "SELECT 5 BETWEEN 1 AND 9" "SELECT 1 IN (1, 2)" "SELECT x FROM t WHERE y = 1" "SELECT 1;" "SELECT 1 ; SELECT 2" "SELECT 3 FROM t LIMIT 5" "SELECT ROUND(2.5, 1)" "SELECT CASE WHEN 1 THEN 2 END"} { if {[parseBoth $t]} { incr pp } else { incr pf ; puts "PARSE DIFFERS on <$t>" } }
for {set i 0} {$i < $n / 4} {incr i} {
    set t ""
    for {set j 0} {$j < 1 + int(rand() * 12)} {incr j} { append t [lindex {"SELECT " "1" ", " "2.5" " 'x'" "(" ")" " + " "VALUES " " FROM t " ";" " AS a" "NULL" "-"} [expr {int(rand() * 14)}]] }
    if {[parseBoth $t]} { incr pp } else { incr pf ; if {$pf < 6} { puts "PARSE DIFFERS on <$t>" } }
}
incr pass $pp ; incr fail $pf
puts "tokenizer and parser shortcut: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
