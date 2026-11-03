# What happens when things go wrong, and in odd corners:
#   errors / cancels in the middle of spilling statements leave nothing behind (files, state, scratch tables)
#   statements are all-or-nothing, also when they spill and when big deletes rebuild the table
#   a statement cannot be started from inside another one
#   bad temp folder, read-only files, several databases, empty tables, persistence after a rebuild
#   tclsh tests/robustness.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
set f1 $tmp/mkitsql_rb1_[pid].mk ; set f2 $tmp/mkitsql_rb2_[pid].mk
file delete $f1 $f2
set db [mkitsql::db::openFile $f1 -create]
proc q {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [q $sql] rows }
proc one {sql} { lindex [rows $sql] 0 0 }
proc err {sql} { if {[catch {q $sql} m]} { return $m } ; return "(no error)" }
proc spills {} { llength [glob -nocomplain -directory [mkitsql::tmpDir] mkitsql_[pid]_*.spill] }
proc leftovers {} { list [spills] [array size ::mkitsql::S] [llength [lsearch -all -glob [mkitsql::db::views $::db] __mkitsql_tmp*]] }
proc setBudget {mem chunk bulk} { set ::mkitsql::memBytes $mem ; set ::mkitsql::chunk $chunk ; set ::mkitsql::bulkMin $bulk }
proc fresh {} {
    q "DROP TABLE IF EXISTS big" ; q "DROP TABLE IF EXISTS other"
    q "CREATE TABLE big (id INT, g INT, s TEXT, kids TABLE (k TEXT))"
    set v {}
    for {set i 0} {$i < 600} {incr i} { lappend v "($i, [expr {$i % 7}], 'n$i')" }
    q "INSERT INTO big (id, g, s) VALUES [join $v ,]"
    q "INSERT INTO big\[3\].kids VALUES ('a'), ('b')"
    q "CREATE TABLE other (id INT, w INT)"
    q "INSERT INTO other SELECT id, g FROM big WHERE id < 50"
    q "COMMIT"
}
proc snapshot {} { list [rows "SELECT id, g, s FROM big ORDER BY id"] [rows "SELECT k FROM big\[3\].kids"] [rows "SELECT * FROM other ORDER BY id"] }

foreach cfg {{33554432 2000 20000} {1 7 20000} {50 3 1} {1 1 1}} {
    lassign $cfg mem chunk bulk
    set tag "\[mem $mem chunk $chunk bulk $bulk\]"
    setBudget $mem $chunk $bulk
    fresh
    set base [snapshot]

    # ---- an error in the middle leaves nothing behind and changes nothing --------------------------------
    foreach {label sql} {
        sort    {SELECT id, 100 / (id - 500) FROM big ORDER BY 2}
        group   {SELECT g, 100 / (MAX(id) - 599) FROM big GROUP BY g ORDER BY 1}
        distinct {SELECT DISTINCT 100 / (id - 450) FROM big}
        join    {SELECT a.id, 100 / (b.id - 300) FROM big a JOIN big b ON a.g = b.g ORDER BY 1}
        window  {SELECT id, 100 / (id - 400), ROW_NUMBER() OVER (ORDER BY s) FROM big}
        update  {UPDATE big SET g = 100 / (id - 500)}
        updstr  {UPDATE big SET s = s || CAST(100 / (id - 500) AS TEXT)}
        delete  {DELETE FROM big WHERE 100 / (id - 500) > 0}
        insert  {INSERT INTO other SELECT id + 1000, 100 / (id - 300) FROM big}
        ctas    {CREATE TABLE made AS SELECT id, 100 / (id - 300) AS z FROM big}
        merge   {MERGE INTO other o USING big b ON o.id = b.id WHEN MATCHED THEN UPDATE SET w = 100 / (b.id - 20)}
        overflow {UPDATE big SET g = id * 10000000}
        dblmerge {MERGE INTO other o USING (SELECT g AS k FROM big WHERE id < 30) b ON o.id = b.k WHEN MATCHED THEN DELETE}
    } {
        set m [err $sql]
        check "$tag $label fails cleanly" [expr {$m ne "(no error)" && ![string match "*while executing*" $m]}] 1
        check "$tag $label leaves nothing behind" [leftovers] {0 0 0}
        check "$tag $label changes nothing" [snapshot] $base
        check "$tag $label: table 'made' not created" [mkitsql::db::hasView $db made] 0
    }
    check "$tag still works after the errors" [one "SELECT COUNT(*) FROM big"] 600

    # ---- cancel in the middle ---------------------------------------------------------------------------------
    foreach {label sql} {
        sort   {SELECT id FROM big ORDER BY s DESC}
        group  {SELECT s, COUNT(*) FROM big GROUP BY s}
        join   {SELECT a.id FROM big a JOIN big b ON a.id = b.id}
        update {UPDATE big SET s = s || 'x'}
        delete {DELETE FROM big WHERE id % 2 = 0}
        window {SELECT id, SUM(g) OVER (PARTITION BY s) FROM big}
    } {
        foreach after {1 3 9} {
            set ::calls 0
            set mkitsql::progressHook [list apply {{after} { if {[incr ::calls] >= $after} { set ::mkitsql::cancel 1 } }} $after]
            set m [err $sql]
            set mkitsql::progressHook ""
            check "$tag cancel $label after $after: reported or finished" [expr {$m eq "Cancelled" || $m eq "(no error)"}] 1
            check "$tag cancel $label after $after: nothing left" [leftovers] {0 0 0}
            if {$m eq "Cancelled"} { check "$tag cancel $label after $after: unchanged" [snapshot] $base }
            if {$m eq "(no error)"} { q "ROLLBACK" }
        }
    }
    check "$tag works after cancels" [one "SELECT COUNT(*) FROM big"] 600
}
setBudget 33554432 2000 20000

# ---- a statement cannot be started from inside another one ------------------------------------------------------
fresh
set ::inner {} ; set ::calls 0
proc cb {rows} { incr ::calls ; set ::inner [expr {[catch {mkitsql::run {SELECT 1} $::db} m] ? $m : "ran"}] ; return 0 }
set r [mkitsql::stream {SELECT id FROM big ORDER BY s} $db {} cb]
check nested_refused [string match "A statement cannot be run while another one is running*" $::inner] 1
check nested_outer_completes [dict get $r count] 600
check nested_after [one "SELECT COUNT(*) FROM big"] 600
set mkitsql::progressHook {apply {{} { catch {mkitsql::run {SELECT 1} $::db} ::nestedMsg }}}
q "SELECT COUNT(id) FROM big"
set mkitsql::progressHook ""
check nested_in_progress_hook [string match "A statement cannot be run*" $::nestedMsg] 1
check nested_flag_reset [one "SELECT 1"] 1
catch {err "SELECT nosuchcolumn FROM big"}
check nested_flag_reset_after_error [one "SELECT 2"] 2

# ---- a rebuild that fails half way ------------------------------------------------------------------------------
# inject a Metakit failure into the copy
rename ::mk::row ::mk::row_real
set ::failAppendOn "" ; set ::failAfter 0
proc ::mk::row {cmd args} {
    if {$cmd eq "append" && $::failAppendOn ne "" && [string match $::failAppendOn [lindex $args 0]] && [incr ::failAfter -1] < 0} { error "injected: append failed" }
    return [::mk::row_real $cmd {*}$args]
}
setBudget 33554432 2000 1
fresh
set base [snapshot]
set ::failAppendOn "*.__mkitsql_tmp_*" ; set ::failAfter 100
set m [err "DELETE FROM big WHERE id % 2 = 0"]
set ::failAppendOn ""
check rebuild_fail1_msg [string match "*injected: append failed*" $m] 1
check rebuild_fail1_unchanged [snapshot] $base
check rebuild_fail1_scratch_dropped [llength [lsearch -all -glob [mkitsql::db::views $db] __mkitsql_tmp*]] 0
set ::failAfter 5 ; set ::failAppendOn "*.__mkitsql_tmp_*"
set m [err "UPDATE big SET s = s || 'x'"]
set ::failAppendOn ""
check rebuild_fail2_msg [string match "*injected: append failed*" $m] 1
check rebuild_fail2_unchanged [snapshot] $base
check rebuild_fail2_scratch_dropped [llength [lsearch -all -glob [mkitsql::db::views $db] __mkitsql_tmp*]] 0
# failure while copying back (after the table was emptied): reported, scratch kept, ROLLBACK restores
set ::failAppendOn "$db.big" ; set ::failAfter 10
set m [err "DELETE FROM big WHERE id % 2 = 0"]
set ::failAppendOn ""
check rebuild_fail3_msg [string match "*injected: append failed*ROLLBACK restores it*scratch table*" $m] 1
q "ROLLBACK"
check rebuild_fail3_rollback_restores [snapshot] $base
check rebuild_fail3_no_scratch_after_rollback [llength [lsearch -all -glob [mkitsql::db::views $db] __mkitsql_tmp*]] 0
rename ::mk::row {}
rename ::mk::row_real ::mk::row
check rebuild_works_again [string match "*deleted*" [dict get [q "DELETE FROM big WHERE id % 2 = 0"] text]] 1
check rebuild_count [one "SELECT COUNT(*) FROM big"] 300
q "ROLLBACK"
setBudget 33554432 2000 20000

# ---- persistence after a rebuild --------------------------------------------------------------------------------
setBudget 50 3 1
fresh
q "DELETE FROM big WHERE id % 3 = 0"
q "UPDATE big SET s = UPPER(s) || '!' WHERE id % 2 = 0"
set expectBig [rows "SELECT id, g, s FROM big ORDER BY id"]
set expectKids [rows "SELECT k FROM big\[3\].kids"]
q "COMMIT"
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f1]
check persist_rows [rows "SELECT id, g, s FROM big ORDER BY id"] $expectBig
check persist_count [one "SELECT COUNT(*) FROM big"] 400
check persist_no_scratch [llength [lsearch -all -glob [mkitsql::db::views $db] __mkitsql_tmp*]] 0
check persist_subview_row_ids_shifted [llength $expectKids] [llength [rows "SELECT k FROM big\[2\].kids"]]
setBudget 33554432 2000 20000

# ---- several databases at once -------------------------------------------------------------------------------------
set db2 [mkitsql::db::openFile $f2 -create]
mkitsql::run "CREATE TABLE other (id INT, w INT)" $db2
mkitsql::run "INSERT INTO other VALUES (1, 100), (2, 200), (3, 300), (4, 400)" $db2
mkitsql::run "COMMIT" $db2
foreach cfg {{33554432 2000 20000} {1 1 1}} {
    lassign $cfg mem chunk bulk
    setBudget $mem $chunk $bulk
    set res {}
    lappend res [dict get [mkitsql::run "SELECT a.id, b.w FROM $db.big a JOIN $db2.other b ON a.id = b.id ORDER BY a.id" $db] rows]
    mkitsql::run "CREATE TABLE $db2.copy AS SELECT id, g FROM $db.big WHERE id < 10" $db
    lappend res [dict get [mkitsql::run "SELECT * FROM $db2.copy ORDER BY id" $db] rows]
    mkitsql::run "UPDATE $db2.copy SET g = (SELECT COUNT(*) FROM $db.big x WHERE x.g = copy.g)" $db
    lappend res [dict get [mkitsql::run "SELECT * FROM $db2.copy ORDER BY id" $db] rows]
    mkitsql::run "DELETE FROM $db.big WHERE id IN (SELECT id FROM $db2.copy)" $db
    lappend res [dict get [mkitsql::run "SELECT COUNT(*) FROM $db.big" $db] rows]
    mkitsql::run "ROLLBACK" $db ; mkitsql::run "ROLLBACK" $db2
    if {![info exists first]} { set first $res } else { check "multi-db results equal for $cfg" $res $first }
    check "multi-db $cfg: spill" [leftovers] {0 0 0}
}
check multi_db_join_nonempty [expr {[llength [lindex $first 0]] > 0}] 1
mkitsql::db::closeFile $db2

# ---- read-only file ----------------------------------------------------------------------------------------------------
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f1 -readonly]
setBudget 1 1 1
check ro_select_spills [one "SELECT COUNT(*) FROM (SELECT id FROM big ORDER BY s) x"] 400
foreach sql {"DELETE FROM big WHERE id < 5" "UPDATE big SET g = 1" "DROP TABLE big" "INSERT INTO other VALUES (1, 1)" "CREATE TABLE zz (a INT)" "ALTER TABLE big ADD COLUMN q INT"} {
    check "ro refuses: $sql" [string match "*read-only*" [err $sql]] 1
}
check ro_untouched [one "SELECT COUNT(*) FROM big"] 400
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f1]
setBudget 33554432 2000 20000

# ---- temp folder problems ----------------------------------------------------------------------------------------------
set mkitsql::tempDir "$tmp/mkitsql_no_such_dir_[pid]"
setBudget 1 1 20000
check badtemp_msg [string match "*temporary files*not exist or is not writable*" [err "SELECT id FROM big ORDER BY s"]] 1
check badtemp_nospill_ok [one "SELECT COUNT(*) FROM big"] 400
set mkitsql::tempDir ""
check badtemp_recovers [one "SELECT COUNT(*) FROM (SELECT id FROM big ORDER BY s) x"] 400
setBudget 33554432 2000 20000

# ---- empty and tiny inputs through every operator, spilled and not -----------------------------------------------------------
q "CREATE TABLE e (id INT, g INT, s TEXT)"
q "CREATE TABLE one (id INT, g INT, s TEXT)"
q "INSERT INTO one VALUES (1, 1, 'only')"
set shapes {
    {SELECT * FROM %T ORDER BY id}
    {SELECT DISTINCT s FROM %T}
    {SELECT g, COUNT(*), SUM(id), MIN(s), MAX(s), AVG(id) FROM %T GROUP BY g}
    {SELECT COUNT(*), SUM(id), MIN(s), MAX(s), AVG(id), COUNT(DISTINCT s), SUM(DISTINCT id), STRING_AGG(s, ',') FROM %T}
    {SELECT g, COUNT(DISTINCT s) FROM %T GROUP BY g}
    {SELECT a.id FROM %T a JOIN %T b ON a.id = b.id}
    {SELECT a.id, b.id FROM %T a LEFT JOIN %T b ON a.s = b.s}
    {SELECT a.id, b.id FROM %T a FULL JOIN big b ON a.id = b.id ORDER BY 1, 2 LIMIT 5}
    {SELECT a.id, b.id FROM %T a, %T b WHERE a.id < b.id}
    {SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY id), SUM(id) OVER () FROM %T}
    {SELECT id FROM %T UNION SELECT id FROM %T}
    {SELECT id FROM %T INTERSECT SELECT id FROM big}
    {SELECT id FROM big EXCEPT SELECT id FROM %T ORDER BY 1 LIMIT 3}
    {SELECT id FROM %T WHERE id IN (SELECT id FROM big)}
    {SELECT id FROM %T WHERE NOT EXISTS (SELECT 1 FROM big WHERE big.id = %T.id)}
    {SELECT (SELECT MAX(id) FROM %T), (SELECT COUNT(*) FROM %T)}
    {WITH RECURSIVE r(n) AS (SELECT id FROM %T UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r}
    {SELECT id FROM %T ORDER BY id LIMIT 0}
    {SELECT id FROM %T ORDER BY id LIMIT 5 OFFSET 7}
}
foreach T {e one} {
    foreach sh $shapes {
        set sql [string map [list %T $T] $sh]
        setBudget 33554432 2000 20000
        set want [expr {[catch {rows $sql} r] ? "ERR $r" : $r}]
        check "edge $T not an error: [string range $sql 0 50]" [string match "ERR*" $want] 0
        foreach bc {{1 1} {50 3}} {
            setBudget {*}$bc 20000
            set got [expr {[catch {rows $sql} r] ? "ERR $r" : $r}]
            check "edge $T spilled == memory: [string range $sql 0 50]" $got $want
        }
    }
}
setBudget 33554432 2000 20000
check edge_empty_aggregates [rows "SELECT COUNT(*), SUM(id), COUNT(DISTINCT s) FROM e"] {{0 NULL 0}}
check edge_empty_group [rows "SELECT g, COUNT(*) FROM e GROUP BY g"] {}
check edge_one_distinct [rows "SELECT COUNT(DISTINCT s), SUM(DISTINCT g) FROM one"] {{1 1}}

catch {mkitsql::db::closeFile $db}
file delete $f1 $f2
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
