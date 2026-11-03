# SIMILAR TO checked against PostgreSQL's documented behaviour (cases from its manual and edge cases), NOT SIMILAR TO, NULLs, ESCAPE, errors.
#   tclsh tests/similar.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_sim_[pid].mk ; file delete $f
set db [mkitsql::db::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc q {sql} { mkitsql::run $sql $::db }
proc t {value pattern want {esc ""}} {
    set e [expr {$esc eq "" ? "" : " ESCAPE '$esc'"}]
    set sql "SELECT CASE WHEN '[string map {' ''} $value]' SIMILAR TO '[string map {' ''} $pattern]'$e THEN 1 ELSE 0 END"
    check "'$value' SIMILAR TO '$pattern'" [lindex [dict get [q $sql] rows] 0 0] $want
}
# the PostgreSQL manual
t abc  abc 1
t abc  a 0
t abc  %(b|d)% 1
t abc  (b|c)% 0
t abc  a% 1
t abc  _b_ 1
t abc  _c 0
t abcabc "(abc){2}" 1
t abc  "(abc){2}" 0
t aaa "a+" 1
t "" "a*" 1
t b "a*" 0
t ab "ab?" 1
t a "ab?" 1
t abb "ab?" 0
t abbb "ab{2,3}" 1
t ab "ab{2,3}" 0
t a1 {a[0-9]} 1
t aX {a[0-9]} 0
t aX {a[^0-9]} 1
t a7 {a[[:digit:]]} 1
t ab {a[[:digit:]]} 0
# . ^ $ are literal in SIMILAR TO (unlike a regular expression)
t a.c "a.c" 1
t abc "a.c" 0
t "a^b" "a^b" 1
t "a\$b" "a\$b" 1
# % and _ cross newlines
t "a\nb" "a%b" 1
t "a\nb" "a_b" 1
# escapes
t "a%b" "a\\%b" 1
t "axb" "a\\%b" 0
t "a%b" "a#%b" 1 "#"
t "a_b" "a#_b" 1 "#"
t "a|b" "a\\|b" 1
t "a(b" "a\\(b" 1
t {a[b} {a\[b} 1
t {a]b} {a\]b} 1
t {a]b} {a[\]]b} 1
t {a-b} {a[x\-]b} 1
t "ab" "(a|b)(a|b)" 1
t "ab" "(a|b)" 0
t "" "" 1
t "x" "" 0
# case sensitive
t ABC abc 0
t Abc "A%" 1
# unicode
t "caf[format %c 233]" "caf_" 1
t "[format %c 26085][format %c 26412]" "__" 1
# NOT SIMILAR TO, NULL, column use
check "NOT SIMILAR TO" [dict get [q "SELECT 'abc' NOT SIMILAR TO 'a%', 'abc' NOT SIMILAR TO 'b%'"] rows] {{0 1}}
check "NULL value" [dict get [q "SELECT NULL SIMILAR TO 'a%', 'a' SIMILAR TO NULL, NULL NOT SIMILAR TO 'a'"] rows] {{NULL NULL NULL}}
q "CREATE TABLE w (id INT, s TEXT)"
q "INSERT INTO w VALUES (1,'apple'),(2,'banana'),(3,'avocado'),(4,'cherry'),(5,'apricot')"
check "in WHERE" [dict get [q "SELECT id FROM w WHERE s SIMILAR TO 'a(p|v)%' ORDER BY id"] rows] {1 3 5}
check "NOT in WHERE" [dict get [q "SELECT id FROM w WHERE s NOT SIMILAR TO '(a|b)%' ORDER BY id"] rows] {4}
check "pattern from a column" [dict get [q "SELECT COUNT(*) FROM w a JOIN w b ON b.s SIMILAR TO a.s || '%'"] rows] 5
# errors are clean SQL errors
foreach {pat frag} {{a(b} "Invalid SIMILAR TO" {a[b} "no closing" {a**} "cannot follow" {a{x}} "bad repetition" {a\\} "escape"} {
    set r [catch {q "SELECT 'a' SIMILAR TO '[string map {\\\\ \\} $pat]'"} err]
    check "error for $pat" [expr {$r && [string match "*$frag*" $err]}] 1
}
# the same query inside a subquery and with parameters
check "parameter" [dict get [mkitsql::run "SELECT id FROM w WHERE s SIMILAR TO ? ORDER BY id" $db {{ch%|ban%}}] rows] {2 4}
mkitsql::db::closeFile $db ; file delete $f ; file delete [mkitsql::db::commitRecord $f]
puts "similar to: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
