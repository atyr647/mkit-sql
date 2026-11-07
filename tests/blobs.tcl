# Large blob values are not read when a statement does not need them (0.5.0):
#   - LENGTH / OCTET_LENGTH of a blob column come from Metakit's size (mk::get -size)
#   - SUBSTR(blob, start, len) with literal numbers reads that range only (mk::channel)
#   - a blob the WHERE clause does not look at is read only for the rows that pass, one row at a time, so a LIMIT or an
#     EXISTS that stops early reads no blob it does not hand on
# Every rewritten form must give exactly what the plain function gives on the whole value (compared below), and the
# reads are counted by wrapping ::mk::get.
#   tclsh tests/blobs.tcl          (MKIT_MK4TCL and MKIT_BACKEND as for the other tests)
set here [file dirname [file normalize [info script]]]
source $here/mk4load.tcl
source $here/loadengine.tcl
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_blobs_[pid].mk
file delete $f
set db [store::openFile $f -create]
set pass 0 ; set fail 0
proc check {name got want} {
    global pass fail
    if {$got eq $want} { incr pass } else { incr fail ; puts "FAIL $name\n   got:  [string range $got 0 300]\n   want: [string range $want 0 300]" }
}
proc run {sql} { mkitsql::run $sql $::db }
proc rows {sql} { dict get [run $sql] rows }

# a table with small blobs, an empty one, and one "big" one (4 MB here: big enough to see, small enough for the stand-in)
run "CREATE TABLE img (id INT, name VARCHAR, data BLOB, note VARCHAR)"
set big [string repeat [binary format c* {0 1 2 3 255 254 65 66}] 524288]
set i 0
foreach {name data} [list small abc empty "" big $big tiny [binary format c* {0 255}] text "hello world"] {
    incr i
    store::appendRow $db.img {id name data note} [list $i $name $data "row $i"]
}
run "COMMIT"

# count every read of the whole `data` value
set ::fullReads 0
rename ::mk::get ::mk::get_real
proc ::mk::get {cursor args} {
    if {[lindex $args 0] ne "-size" && [lsearch -exact $args data] >= 0} { incr ::fullReads }
    return [::mk::get_real $cursor {*}$args]
}
proc reads {sql} { set ::fullReads 0 ; set r [rows $sql] ; return [list $::fullReads $r] }

# ---- LENGTH / OCTET_LENGTH: the size, never the value
check length [reads "SELECT id, LENGTH(data) FROM img ORDER BY id"] [list 0 [list {1 3} {2 0} [list 3 [string length $big]] {4 2} {5 11}]]
check octet_length [reads "SELECT OCTET_LENGTH(data) FROM img WHERE id = 3"] [list 0 [list [string length $big]]]
check char_length [reads "SELECT CHAR_LENGTH(data), CHARACTER_LENGTH(data) FROM img WHERE id = 1"] {0 {{3 3}}}
check length_where [reads "SELECT name FROM img WHERE LENGTH(data) > 1000"] {0 big}
check length_order [reads "SELECT name FROM img ORDER BY LENGTH(data) DESC, id LIMIT 2"] {0 {big text}}
check length_agg [reads "SELECT SUM(LENGTH(data)), MAX(LENGTH(data)) FROM img"] [list 0 [list [list [expr {16 + [string length $big]}] [string length $big]]]]
check length_names [dict get [run "SELECT LENGTH(data) AS n, LENGTH(data) FROM img WHERE id = 1"] cols] {n LENGTH(data)}
# the same numbers as the function on the whole value (COALESCE(data, data) is not a bare column, so it is not rewritten)
check length_same [rows "SELECT LENGTH(data) FROM img ORDER BY id"] [rows "SELECT LENGTH(COALESCE(data, data)) FROM img ORDER BY id"]
# OCTET_LENGTH of a blob column is its size in bytes (on a computed value the function still counts the UTF-8 form of its text)
check octet_is_bytes [rows "SELECT OCTET_LENGTH(data) FROM img ORDER BY id"] [rows "SELECT LENGTH(data) FROM img ORDER BY id"]
# a text column keeps counting characters, not bytes
check length_text [rows "SELECT LENGTH(note) FROM img WHERE id = 1"] 5

# ---- SUBSTR: the range only (through mk::channel; the stand-in has none, so there it reads the value, with the same result)
set ranged [llength [info commands ::mk::channel]]
set ::fullReads 0
set bad {}
foreach {s l} {1 0 1 1 1 4 2 2 3 10 4 1 5 3 1 100 12 5 4194300 10 4194305 4 4194304 1 9999999 3} {
    set want [rows "SELECT SUBSTR(COALESCE(data, data), $s, $l) FROM img ORDER BY id"]
    set ::fullReads 0
    set got [rows "SELECT SUBSTR(data, $s, $l) FROM img ORDER BY id"]
    if {$got ne $want || ($ranged && $::fullReads)} { lappend bad "$s,$l reads $::fullReads" }
}
check substr_same $bad {}
set r [reads "SELECT SUBSTRING(data FROM 5 FOR 4) FROM img WHERE id = 3"]
check substring_form [list [expr {$ranged ? [lindex $r 0] : 0}] [lindex $r 1]] [list 0 [list [list [binary format c* {-1 -2 65 66}]]]]
check substr_text_untouched [rows "SELECT SUBSTR(note, 1, 3) FROM img WHERE id = 2"] {row}
# not literal numbers, or a negative length: the function as before (it reads the value, and fails the same way)
check substr_expr_args [lindex [reads "SELECT SUBSTR(data, id, 2) FROM img WHERE id = 1"] 1] ab
check substr_negative [catch {rows "SELECT SUBSTR(data, 1, -1) FROM img"} m] 1

# ---- late reads: the blob only for the rows the filter lets through
check late_where [reads "SELECT id, data FROM img WHERE id = 1"] {1 {{1 abc}}}
check late_star_limit [lindex [reads "SELECT * FROM img LIMIT 1"] 0] 1
check late_star_where_note [lindex [reads "SELECT * FROM img WHERE note = 'row 4'"] 0] 1
check late_exists [lindex [reads "SELECT 1 WHERE EXISTS (SELECT data FROM img)"] 0] 1
check late_none [lindex [reads "SELECT data FROM img WHERE id > 100"] 0] 0
# a filter on the blob itself reads it first, of course, and still finds the right rows
check filter_on_blob [lindex [reads "SELECT id FROM img WHERE data = X'616263'"] 1] 1
check filter_on_blob_late [reads "SELECT id, LENGTH(data) FROM img WHERE data = X'00FF'"] {5 {{4 2}}}
# correlated: the subquery's filter mentions the outer blob, so the outer scan reads it before filtering
check correlated [rows "SELECT a.id FROM img a WHERE EXISTS (SELECT 1 FROM img b WHERE b.id = 1 AND b.data = a.data) ORDER BY a.id"] 1
check join [rows "SELECT a.id, b.id FROM img a JOIN (SELECT * FROM img WHERE id <> 3) b ON a.data = b.data WHERE a.id = 4"] {{4 4}}
check join_late [lindex [reads "SELECT a.name, b.data FROM img a JOIN img b ON a.id = b.id WHERE a.id = 2"] 1] {{empty {}}}
check group_by_blob [rows "SELECT COUNT(*) FROM (SELECT data FROM img GROUP BY data) x"] 5
# the whole value, when asked for, is exactly the stored one
check whole [expr {[lindex [rows "SELECT data FROM img WHERE id = 3"] 0 0] eq $big}] 1
check subview_blob [catch {rows "SELECT LENGTH(data) FROM img x WHERE x.id = 3"}] 0

rename ::mk::get {} ; rename ::mk::get_real ::mk::get
store::closeFile $db
file delete $f
puts "blobs: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
