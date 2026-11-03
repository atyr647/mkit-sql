# Audit of the expression compiler's string -> code boundary.
#
#   1. verifyCode accepts the shapes the compiler emits and rejects everything else (handcrafted cases).
#   2. A corpus of hostile literals, identifiers, aliases and parameters is compiled; every generated
#      proc passes the verifier, and no hostile code runs.
#   3. MUTATION TEST: take every generated proc body, inject a command (";exit 3;", "]\n exit 3 \n[", ...)
#      at every position, and execute the mutated body in a throw-away interpreter where `exit` is a
#      tripwire.  Whenever the injected command would really run, the verifier MUST have rejected the
#      body.  (accepted => nothing injected can run.)
#   tclsh tests/codegen_audit.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_cg_[pid].mk
file delete $f
set db [store::openFile $f -create]
fconfigure stdout -buffering line
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
set ::pwned 0

# ---- 1. handcrafted cases ------------------------------------------------------------------------
proc ver {code} { expr {[catch {mkitsql::verifyCode $code}] ? "rejected" : "accepted"} }
foreach {name code want} {
    ok_lit      {return abc}                                                         accepted
    ok_col      {return [lindex $r0 3]}                                              accepted
    ok_outer    {return [lindex [lindex $outer 0] 2]}                                accepted
    ok_rt       {return [::mkitsql::rt::add [lindex $r0 0] 5]}                       accepted
    ok_braced   {return [::mkitsql::rt::eq_s {a b} \{x]}                             accepted
    ok_escaped  {return [::mkitsql::rt::cat a\;b c\[d\ e]}                           accepted
    ok_if       {return [if {[set t1 [lindex $r0 0]] eq "0"} {set _ 0} else {::mkitsql::rt::and2 $t1 1}]} accepted
    ok_case     {return [if {[string equal [::mkitsql::rt::eq_n 1 2] 1]} {set _ 1} else {set _ 2}]}       accepted
    ok_list     {list [lindex $r0 0] a [::mkitsql::rt::add 1 2]}                     accepted
    bad_exit    {return [exit 7]}                                                    rejected
    bad_semi    {return a; exit 7}                                                   rejected
    bad_nl      "return a\nexit 7"                                                   rejected
    bad_nested  {return [::mkitsql::rt::add [exit 7] 1]}                             rejected
    bad_set     {return [set ::pwned 1]}                                             rejected
    bad_set2    {return [set x 1]}                                                   rejected
    bad_var     {return $::env(HOME)}                                                rejected
    bad_var2    {return $x}                                                          rejected
    bad_arr     {return $r0(1)}                                                      rejected
    bad_quote   {return "x"}                                                         rejected
    bad_bare    {return a$b}                                                         rejected
    bad_bare2   {return a[exit 7]}                                                   rejected
    bad_unknown {return [::mkitsql::rt::nosuchproc 1]}                               rejected
    bad_ns      {return [::mkitsql::rt::add::x 1]}                                   rejected
    bad_other   {return [::mkitsql::fail x]}                                         rejected
    bad_lindex  {return [lindex $x 3]}                                               rejected
    bad_lindex2 {return [lindex $r0 [exit 7]]}                                       rejected
    bad_string  {return [string map {a b} x]}                                        rejected
    bad_if      {return [if {[exit 7]} {set _ 1} else {set _ 2}]}                    rejected
    bad_if2     {return [if {1} {set _ 1} else {set _ 2}]}                           rejected
    bad_if3     {return [if {[::mkitsql::rt::eq_n 1 1] ; exit 7} {set _ 1} else {set _ 2}]} rejected
    bad_ifbody  {return [if {[::mkitsql::rt::eq_n 1 1] eq "0"} {exit 7} else {set _ 2}]}   rejected
    bad_ifbody2 {return [if {[::mkitsql::rt::eq_n 1 1] eq "0"} {set _ 1} else {set _ 2; exit 7}]} rejected
    bad_expr    {return [expr {1}]}                                                      rejected
    bad_uplevel {return [uplevel 1 {set x 1}]}                                           rejected
    bad_comment {# x
return 1}                                                                              rejected
} { check codegen_$name [ver $code] $want }
check codegen_bad_brace [ver "return \[::mkitsql::rt::add \{a 1\]"] rejected
check codegen_bad_close [ver "return a\]"] rejected
check codegen_bad_open  [ver "return \[::mkitsql::rt::add 1 2"] rejected

# ---- 2. corpus -----------------------------------------------------------------------------------
set bodies {}
rename ::mkitsql::verifyCode ::mkitsql::verifyCode_real
proc ::mkitsql::verifyCode {text} { lappend ::bodies $text ; ::mkitsql::verifyCode_real $text }
proc run {sql {p {}}} { mkitsql::run $sql $::db $p }
set nasty [list \
    {[set ::pwned 1]} {$::pwned} {\[set ::pwned 1\]} "\}\[set ::pwned 1\]\{" "\"; set ::pwned 1; \"" \
    "x\\" "\\" "\{" "\}" "\{\}" "\{\{" "\}\}" "a b" "line1\nline2" "tab\there" {[exit 7]} {\x41} {$\{x\}} \
    {%} {_} {;} {;;} "\[" "\]" "\"" {""} {'} "\$x(1)" {$::env(HOME)} "\\\n" "\{\\" "set ::pwned 1" \
    "a\0b" {\0} {[list} {]]} {#} {# comment} "if \{1\} \{set ::pwned 1\}" {} "\}\n\[exit 7\]\n\{" "\\\}\[exit 7\]" \
    "\\\\\[exit 7\]" "a\\" "\\\\" "\{a\\" "x;exit 7;y" "x\nexit 7\ny" "\[::mkitsql::rt::add 1 2\]" "\$r0" "\$outer" "\[lindex \$r0 0\]"]
run "CREATE TABLE ct (id INT, a TEXT, b TEXT, n REAL)"
run "INSERT INTO ct VALUES (1, 'x', 'y', 1.5), (2, 'p', 'q', 2.5)"
set shapes {
    {SELECT %L}
    {SELECT %L || a FROM ct}
    {SELECT CASE WHEN a = %L THEN %L ELSE b END FROM ct}
    {SELECT COALESCE(NULLIF(a, %L), %L) FROM ct}
    {SELECT id FROM ct WHERE a IN (%L, 'q', b) AND b <> %L}
    {SELECT id FROM ct WHERE a LIKE %L OR b NOT LIKE %L ESCAPE '!'}
    {SELECT id FROM ct WHERE a BETWEEN %L AND %L}
    {SELECT UPPER(%L), LENGTH(%L), REPLACE(a, %L, %L) FROM ct}
    {SELECT a FROM ct WHERE EXISTS (SELECT 1 FROM ct c2 WHERE c2.a = ct.a AND c2.b <> %L)}
    {SELECT (SELECT MAX(b) FROM ct c2 WHERE c2.a <> %L) FROM ct}
    {SELECT a FROM ct WHERE a = ANY (SELECT b FROM ct WHERE b <> %L)}
    {SELECT SUM(n) FILTER (WHERE a <> %L) FROM ct}
    {SELECT a, ROW_NUMBER() OVER (PARTITION BY a ORDER BY b) FROM ct WHERE b <> %L}
    {SELECT a FROM ct GROUP BY a HAVING MAX(b) <> %L}
    {SELECT a FROM ct ORDER BY CASE WHEN a = %L THEN 0 ELSE 1 END}
    {SELECT * FROM (SELECT a AS v FROM ct WHERE a <> %L) t WHERE v <> %L}
    {WITH w AS (SELECT %L AS v) SELECT v FROM w}
    {SELECT a FROM ct JOIN (SELECT %L AS k) j ON ct.a = j.k}
    {SELECT CAST(%L AS TEXT), CAST(n AS TEXT) FROM ct}
    {SELECT %L IS NULL, %L IS DISTINCT FROM a FROM ct}
}
foreach s $nasty {
    set L "'[string map {' ''} $s]'"
    foreach sh $shapes {
        set sql [string map [list %L $L] $sh]
        catch {run $sql}
    }
    # identifiers and aliases
    set qi "\"[string map {\" \"\"} $s]\""
    catch {run "SELECT a AS $qi FROM ct"}
    catch {run "SELECT $qi.a FROM ct AS $qi"}
    catch {run "SELECT $qi FROM (SELECT a AS $qi FROM ct) t"}
    catch {run "SELECT a FROM ct ORDER BY $qi"}
    # parameters, positional and named
    catch {run "SELECT ?, a || ? FROM ct WHERE a <> ?" [list $s $s $s]}
    catch {run "SELECT :v, CASE WHEN a = :v THEN :v ELSE b END FROM ct" [list v $s]}
}
check corpus_no_code_run $::pwned 0
check corpus_bodies [expr {[llength $bodies] > 3000}] 1
puts "(corpus ready; time [clock seconds]) "
puts "(corpus: [llength $bodies] generated procs)"

# ---- 3. mutation test ----------------------------------------------------------------------------
set child [interp create]
$child eval {namespace eval ::mkitsql::rt {}}
foreach c [info commands ::mkitsql::rt::*] { $child eval [list proc $c args {return 0}] }
set ::tripped 0
$child alias exit ::tripwire
proc ::tripwire {args} { set ::tripped 1 ; return 0 }
set inject [list ";exit 3;" "\nexit 3\n" "\]; exit 3; \[" ";exit 3" " ;exit 3; " "\n;exit 3;\n" "\] exit 3 \["]
set seen [dict create] ; set bodiesU {}
foreach b $bodies { if {![dict exists $seen $b]} { dict set seen $b 1 ; lappend bodiesU $b } }
set muts 0 ; set bad 0 ; set escaped 0 ; set rejectedN 0
expr {srand(11)}
foreach b $bodiesU {
    set n [string length $b]
    # a sample of positions per body (every position for short bodies)
    set step [expr {$n > 120 ? 7 : 1}]
    for {set i 0} {$i <= $n} {incr i $step} {
        foreach inj [lrange $inject [expr {$i % 3}] [expr {$i % 3}]] {
            set mut [string range $b 0 [expr {$i - 1}]]$inj[string range $b $i end]
            incr muts
            set ::tripped 0
            catch {$child eval [list proc ::t {r0 outer} $mut]}
            catch {$child eval [list ::t {a b c d e f g h} {{1 2 3 4 5 6 7 8} {1 2 3 4 5 6 7 8}}]}
            set verdict [catch {mkitsql::verifyCode_real $mut}]
            if {$::tripped} {
                incr escaped
                if {!$verdict} { incr bad ; if {$bad < 5} { puts "ACCEPTED A BODY THAT RUNS exit: [string range $mut 0 200]" } }
            }
            incr rejectedN $verdict
        }
    }
}
puts "(mutations: $muts, of which would run the injected command: $escaped, all of them rejected: [expr {$bad == 0}], rejected overall: $rejectedN)"
check mutation_sound $bad 0
check mutation_effective [expr {$escaped > 1000}] 1
interp delete $child

# ---- 4. the verifier is on by default and an unsafe body is refused with a clear error -------------
check verify_default_on $mkitsql::verifyOn 1
rename ::mkitsql::verifyCode {}
rename ::mkitsql::verifyCode_real ::mkitsql::verifyCode
check refused_msg [string match "internal error: unsafe code*" [expr {[catch {mkitsql::verifyCode "return \[exit 1\]"} m] ? $m : ""}]] 1

store::closeFile $db ; file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
