# DROP TABLE must never leave old rows that a later CREATE TABLE of the same name could resurrect, and a
# failure while emptying the view must ABORT the drop (nothing is caught).  Every failure mode is injected
# by wrapping ::mk::view, so this runs on real Metakit as well as the stand-in, on both storage layers.
#   tclsh tests/dropview.tcl
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set f $tmp/mkitsql_dv_[pid].mk
file delete $f
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  $got\n   want: $want" }
}
proc q {sql} { mkitsql::run $sql $::db }
proc cnt {t} { lindex [dict get [q "SELECT COUNT(*) FROM $t"] rows] 0 0 }
proc err {sql} { if {[catch {q $sql} m]} { return $m } ; return "(no error)" }
proc has {name} { mkitsql::db::hasView $::db $name }

# ---- failure injection --------------------------------------------------------------------------------
# mode: ok | sizeRaises | sizeNoop | sizeAfterRaises | deleteRaises
set ::mode ok ; set ::sizeSets 0
rename ::mk::view ::mk::view_real
proc ::mk::view {cmd args} {
    switch -- $::mode {
        sizeRaises { if {$cmd eq "size" && [llength $args] == 2} { error "injected: cannot resize" } }
        sizeNoop   { if {$cmd eq "size" && [llength $args] == 2} { incr ::sizeSets ; return [::mk::view_real size [lindex $args 0]] } }
        sizeAfterRaises {
            # the resize works, but reading the size back fails
            if {$cmd eq "size" && [llength $args] == 2} { incr ::sizeSets ; ::mk::view_real {*}[linsert $args 0 $cmd] ; return 0 }
            if {$cmd eq "size" && [llength $args] == 1 && $::sizeSets > 0} { error "injected: cannot read size" }
            if {$cmd eq "size" && [llength $args] == 1} { return [::mk::view_real size [lindex $args 0]] }
        }
        deleteRaises { if {$cmd eq "delete"} { error "injected: cannot delete view" } }
    }
    return [::mk::view_real $cmd {*}$args]
}
proc mode {m} { set ::mode $m ; set ::sizeSets 0 }

proc fresh {} {
    global db f
    catch {mkitsql::db::closeFile $db}
    file delete $f
    set db [mkitsql::db::openFile $f -create]
    q "CREATE TABLE t (id INT, name TEXT)"
    q "INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c')"
    q "CREATE TABLE s (id INT, kids TABLE (k TEXT, w INT))"
    q "INSERT INTO s (id) VALUES (10), (11)"
    q "INSERT INTO s\[0\].kids VALUES ('x', 1), ('y', 2)"
    q "INSERT INTO s\[1\].kids VALUES ('z', 3)"
    q "COMMIT"
}

# ---- A. the normal drop really empties the table --------------------------------------------------------
fresh
q "DROP TABLE t"
check A_gone [has t] 0
q "CREATE TABLE t (id INT, name TEXT)"
check A_recreated_empty [cnt t] 0
q "DROP TABLE t"
q "CREATE TABLE t (other REAL)"
check A_recreate_other_layout_empty [cnt t] 0
q "COMMIT"
q "DROP TABLE t"
q "COMMIT"
q "CREATE TABLE t (id INT, name TEXT)"
check A_after_commit_empty [cnt t] 0
q "COMMIT"
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f]
check A_after_reopen_empty [cnt t] 0
check A_other_table_untouched [cnt s] 2

# ---- B. subviews --------------------------------------------------------------------------------------------
fresh
q "DROP TABLE s"
q "CREATE TABLE s (id INT, kids TABLE (k TEXT, w INT))"
check B_top_empty [cnt s] 0
q "INSERT INTO s (id) VALUES (99)"
check B_new_row_has_no_old_kids [lindex [dict get [q "SELECT COUNT(*) FROM s\[0\].kids"] rows] 0 0] 0
q "COMMIT"
mkitsql::db::closeFile $db
set db [mkitsql::db::openFile $f]
check B_after_reopen [list [cnt s] [lindex [dict get [q "SELECT COUNT(*) FROM s\[0\].kids"] rows] 0 0]] {1 0}

# ---- C. emptying raises: the drop is abandoned, nothing is lost ------------------------------------------------
fresh
mode sizeRaises
check C_message [string match "*injected: cannot resize*" [err "DROP TABLE t"]] 1
check C_db_level [expr {[catch {mkitsql::db::dropView $db t} m] ? $m : "no error"}] "injected: cannot resize"
mode ok
check C_view_kept [has t] 1
check C_rows_kept [cnt t] 3
check C_rows_intact [dict get [q "SELECT name FROM t ORDER BY id"] rows] {a b c}
q "DROP TABLE t"
q "CREATE TABLE t (id INT, name TEXT)"
check C_works_after [cnt t] 0

# ---- D. the resize "succeeds" but the rows are still there ------------------------------------------------------
fresh
mode sizeNoop
check D_message [string match "Cannot drop 't': 3 rows could not be cleared.*" [err "DROP TABLE t"]] 1
mode ok
check D_view_kept [has t] 1
check D_rows_kept [cnt t] 3

# ---- E. reading the size back fails -------------------------------------------------------------------------------
fresh
mode sizeAfterRaises
check E_message [string match "*injected: cannot read size*" [err "DROP TABLE t"]] 1
mode ok
check E_view_kept [has t] 1

# ---- F. the final delete fails after the rows were cleared: the error surfaces, no resurrection ---------------
fresh
mode deleteRaises
check F_message [string match "*injected: cannot delete view*" [err "DROP TABLE t"]] 1
mode ok
check F_view_still_listed [has t] 1
check F_rows_cleared [cnt t] 0
q "DROP TABLE t"
q "CREATE TABLE t (id INT, name TEXT)"
check F_recreated_empty [cnt t] 0

# ---- G. errors that are not about emptying ------------------------------------------------------------------------
fresh
check G_missing_db_level [expr {[catch {mkitsql::db::dropView $db nosuch} m] ? $m : "no error"}] "View 'nosuch' does not exist in '$db'."
check G_missing_sql [string match "Unknown table 'nosuch'*" [err "DROP TABLE nosuch"]] 1
check G_if_exists [string match "*does not exist*nothing to do*" [dict get [q "DROP TABLE IF EXISTS nosuch"] text]] 1
check G_twice [string match "Unknown table*" [err "DROP TABLE t; DROP TABLE t"]] 1

# ---- H. rollback after an uncommitted drop gives the table back with its rows ----------------------------------------
fresh
q "DROP TABLE t"
q "ROLLBACK"
check H_back [has t] 1
check H_rows_back [cnt t] 3
q "DROP TABLE s"
q "ROLLBACK"
check H_sub_rows_back [list [cnt s] [lindex [dict get [q "SELECT COUNT(*) FROM s\[0\].kids"] rows] 0 0]] {2 2}

# ---- I. many drops/creates in a row never accumulate rows ----------------------------------------------------------
fresh
for {set i 0} {$i < 20} {incr i} {
    q "INSERT INTO t VALUES ($i, 'n$i')"
    q "DROP TABLE t"
    q "CREATE TABLE t (id INT, name TEXT)"
    if {[cnt t] != 0} { check "I_cycle_$i" [cnt t] 0 ; break }
}
check I_cycles_done [cnt t] 0

# ---- J. DROP inside a statement list with a failing later statement stays consistent ---------------------------
fresh
check J_script [string match "*Unknown*" [err "DROP TABLE t; SELECT * FROM nosuch"]] 1
check J_first_applied [has t] 0

rename ::mk::view {}
rename ::mk::view_real ::mk::view
catch {mkitsql::db::closeFile $db}
file delete $f
puts "$pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
