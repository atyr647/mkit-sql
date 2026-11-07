# Large blob values are not read when a statement does not need them (0.5.0), and big ones can be handed out by reference (0.6.0):
#   - LENGTH / OCTET_LENGTH of a blob column come from Metakit's size (mk::get -size)
#   - SUBSTR(blob, start, len) with literal numbers reads that range only (mk::channel)
#   - a blob the WHERE clause does not look at is read only for the rows that pass, one row at a time, so a LIMIT or an
#     EXISTS that stops early reads no blob it does not hand on
#   - with ::mkitsql::blobLimit set, a blob the outermost SELECT returns as it is comes back as a reference (size, first bytes)
#     when it is bigger, and ::mkitsql::blobRead / blobCopy read it; everything that looks at the value still gets the value
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
set ::fullReads 0 ; set ::bigReads 0
rename ::mk::get ::mk::get_real
proc ::mk::get {cursor args} {
    if {[lindex $args 0] ne "-size" && [lsearch -exact $args data] >= 0} {
        incr ::fullReads
        if {[::mk::get_real $cursor -size data] > 1000} { incr ::bigReads }     ;# (the 4 MB value)
    }
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
check join [rows "SELECT a.id, b.id FROM img a JOIN img b ON a.data = b.data WHERE a.id = 4"] {{4 4}}
# the 4 MB row makes the right side bigger than a small budget: a sort-merge join, whose merge must order keys as its sort does
set saved $::mkitsql::memBytes ; set ::mkitsql::memBytes 1000000
check join_merge_nul [rows "SELECT a.id, b.id FROM img a JOIN img b ON a.data = b.data WHERE a.id IN (1, 4, 5) ORDER BY a.id"] {{1 1} {4 4} {5 5}}
set ::mkitsql::memBytes $saved
check join_late [lindex [reads "SELECT a.name, b.data FROM img a JOIN img b ON a.id = b.id WHERE a.id = 2"] 1] {{empty {}}}
check group_by_blob [rows "SELECT COUNT(*) FROM (SELECT data FROM img GROUP BY data) x"] 5
# the whole value, when asked for, is exactly the stored one
check whole [expr {[lindex [rows "SELECT data FROM img WHERE id = 3"] 0 0] eq $big}] 1
check subview_blob [catch {rows "SELECT LENGTH(data) FROM img x WHERE x.id = 3"}] 0

# ---- big blobs by reference (::mkitsql::blobLimit): the value is not read; its size and first bytes are in the result -------
check limit_default [mkitsql::blobLimit] -1
check whole_by_default [expr {[lindex [rows "SELECT data FROM img WHERE id = 3"] 0 0] eq $big}] 1
check limit_bad [catch {mkitsql::blobLimit -2}] 1
check limit_bad_text [catch {mkitsql::blobLimit lots}] 1
check limit_unchanged [mkitsql::blobLimit] -1
mkitsql::blobLimit 10
proc isref {v} { expr {[mkitsql::blobRef $v] ne ""} }
# the big value is never read whole, wherever the plain blob is selected (with mk::channel; the stand-in reads it to cut the
# head); values of at most 10 bytes are read as they are
proc refreads {sql} { set ::bigReads 0 ; set r [rows $sql] ; return [list [expr {$::ranged ? $::bigReads : 0}] $r] }
lassign [refreads "SELECT id, data FROM img ORDER BY id"] n r
check ref_no_reads $n 0
check ref_small_inline [lrange [lindex $r 0] 0 1] {1 abc}
check ref_empty_inline [lindex $r 1] {2 {}}
check ref_tiny_inline [lindex $r 3 1] [binary format c* {0 255}]
check ref_eleven_bytes_is_a_ref [isref [lindex $r 4 1]] 1
set ref [lindex $r 2 1]
check ref_big [isref $ref] 1
set d [mkitsql::blobRef $ref]
check ref_size [dict get $d size] [string length $big]
check ref_head [dict get $d head] [string range $big 0 9]
check ref_where [list [dict get $d db] [dict get $d path] [dict get $d row] [dict get $d column]] [list $db $db.img 2 data]
check ref_not_for_values [list [mkitsql::blobRef abc] [mkitsql::blobRef ""] [mkitsql::blobRef "\uFDD1junk"] [mkitsql::blobRef "\uFDD1[lrange [string range $ref 1 end] 0 5]"] [mkitsql::blobRef "\uFDD1[lreplace [string range $ref 1 end] 0 0 other]"]] {{} {} {} {} {}}
check ref_read_all [expr {[mkitsql::blobRead $ref] eq $big}] 1
set ::bigReads 0
check ref_read_range [mkitsql::blobRead $ref 4 4] [binary format c* {-1 -2 65 66}]
check ref_read_range_no_whole [expr {$ranged ? $::bigReads : 0}] 0
check ref_read_tail [mkitsql::blobRead $ref [expr {[string length $big] - 2}] 10] AB
check ref_read_past_end [mkitsql::blobRead $ref [expr {[string length $big] + 5}]] ""
check ref_read_zero [mkitsql::blobRead $ref 0 0] ""
check ref_read_bad_offset [catch {mkitsql::blobRead $ref -1}] 1
set out [file rootname $f].out ; set ch [open $out wb]
check ref_copy_size [mkitsql::blobCopy $ref $ch] [string length $big]
close $ch ; set ch [open $out rb] ; set copied [read $ch] ; close $ch ; file delete $out
check ref_copy_bytes [expr {$copied eq $big}] 1
check notref_read [catch {mkitsql::blobRead abc} m] 1
check notref_code [lrange $::errorCode 0 1] {MKIT BLOBREF}
# the forms that pass a plain blob through: *, WHERE / ORDER BY on other columns, LIMIT, joins, subview of the FROM clause
check ref_star [refreads "SELECT * FROM img WHERE id = 3"] [list 0 [list [list 3 big $ref {row 3}]]]
check ref_limit [lindex [refreads "SELECT data FROM img ORDER BY name DESC LIMIT 2"] 0] 0
check ref_order_other [isref [lindex [rows "SELECT data FROM img ORDER BY LENGTH(data) DESC LIMIT 1"] 0 0]] 1
lassign [refreads "SELECT a.name, b.data FROM img a JOIN img b ON a.id = b.id WHERE a.id = 3"] n r
check ref_join [list $n [lindex $r 0 0] [isref [lindex $r 0 1]] [expr {[mkitsql::blobRead [lindex $r 0 1]] eq $big}]] {0 big 1 1}
check ref_left_join_null [rows "SELECT a.id, b.data FROM img a LEFT JOIN img b ON b.id = a.id + 100 WHERE a.id = 3"] {{3 NULL}}
check ref_alias_names [dict get [run "SELECT data AS payload, id FROM img WHERE id = 3"] cols] {payload id}
check ref_types [dict get [run "SELECT data FROM img WHERE id = 3"] types] B
# ... and everything that looks at the value still reads it whole and gives the value
check whole_where_on_blob [expr {[lindex [rows "SELECT data FROM img WHERE data <> X'00'  AND id = 3"] 0 0] eq $big}] 1
mkitsql::blobLimit -1 ; set want [rows "SELECT id, data FROM img ORDER BY data DESC, id"] ; mkitsql::blobLimit 10
check whole_order_by_blob [expr {[rows "SELECT id, data FROM img ORDER BY data DESC, id"] eq $want}] 1
check whole_order_by_position [isref [lindex [rows "SELECT data FROM img ORDER BY 1 DESC LIMIT 1"] 0 0]] 0
check whole_distinct [isref [lindex [rows "SELECT DISTINCT data FROM img WHERE id = 3"] 0 0]] 0
check whole_group [isref [lindex [rows "SELECT data, COUNT(*) FROM img WHERE id = 3 GROUP BY data"] 0 0]] 0
check whole_expr [string length [lindex [rows "SELECT data || X'00' FROM img WHERE id = 3"] 0 0]] [expr {[string length $big] + 1}]
check whole_coalesce [expr {[lindex [rows "SELECT COALESCE(data, data) FROM img WHERE id = 3"] 0 0] eq $big}] 1
check whole_derived [expr {[lindex [rows "SELECT x.data FROM (SELECT data FROM img WHERE id = 3) x"] 0 0] eq $big}] 1
check whole_cte [expr {[lindex [rows "WITH c AS (SELECT data FROM img WHERE id = 3) SELECT data FROM c"] 0 0] eq $big}] 1
check whole_union_all [isref [lindex [rows "SELECT data FROM img WHERE id = 3 UNION ALL SELECT data FROM img WHERE id = 1"] 0 0]] 0
check whole_scalar_sub [expr {[lindex [rows "SELECT (SELECT data FROM img WHERE id = 3)"] 0 0] eq $big}] 1
check whole_correlated [isref [lindex [rows "SELECT a.data FROM img a WHERE EXISTS (SELECT 1 FROM img b WHERE b.data = a.data AND b.id = 3)"] 0 0]] 0
check length_still_size [lindex [reads "SELECT LENGTH(data) FROM img WHERE id = 3"] 0] 0
set r [lindex [rows "SELECT data, data FROM img WHERE id = 3"] 0]
check same_item_twice [list [isref [lindex $r 0]] [isref [lindex $r 1]]] {1 1}
# statements that store what they select get the values, never references
run "CREATE TABLE copy1 AS SELECT id, data FROM img"
check ctas_values [expr {[mk::get $db.copy1!2 data] eq $big}] 1
run "CREATE TABLE copy2 (id INT, data BLOB)"
run "INSERT INTO copy2 SELECT id, data FROM img WHERE id = 3"
check insert_select_values [expr {[mk::get $db.copy2!0 data] eq $big}] 1
run "UPDATE copy2 SET data = (SELECT data FROM img WHERE id = 3)"
check update_values [expr {[mk::get $db.copy2!0 data] eq $big}] 1
run "DROP TABLE copy1" ; run "DROP TABLE copy2"
# a spilling sort carries references intact (a tiny budget)
set saved $::mkitsql::memBytes ; set ::mkitsql::memBytes 200
set r [rows "SELECT name, data FROM img ORDER BY name"]
set ::mkitsql::memBytes $saved
check ref_spilled [expr {[mkitsql::blobRead [lindex $r 0 1]] eq $big}] 1
# streaming hands out references too
set ::streamed {}
proc takeChunk {chunk} { lappend ::streamed {*}$chunk ; return 0 }
mkitsql::stream "SELECT id, data FROM img WHERE id >= 3 ORDER BY id" $db {} takeChunk
check stream_ref [list [isref [lindex $::streamed 0 1]] [expr {[mkitsql::blobRead [lindex $::streamed 0 1]] eq $big}] [lindex $::streamed 1 1]] [list 1 1 [binary format c* {0 255}]]
# a reference is good while the database is unchanged: any change, a rollback or closing it makes it stale
set ref [lindex [rows "SELECT data FROM img WHERE id = 3"] 0 0]
store::setCell $db.img 0 note "changed"
check stale_after_write [catch {mkitsql::blobRead $ref} m] 1
check stale_code [lrange $::errorCode 0 1] {MKIT BLOBSTALE}
check stale_copy [catch {mkitsql::blobCopy $ref stdout}] 1
run "ROLLBACK"
check stale_after_rollback [catch {mkitsql::blobRead $ref}] 1
set ref [lindex [rows "SELECT data FROM img WHERE id = 3"] 0 0]
check fresh_after_rerun [expr {[mkitsql::blobRead $ref 0 3] eq [string range $big 0 2]}] 1
# the limit 0: every non-empty blob is a reference with no head
mkitsql::blobLimit 0
set r [rows "SELECT data FROM img ORDER BY id"]
check limit0 [list [isref [lindex $r 0 0]] [lindex $r 1 0] [dict get [mkitsql::blobRef [lindex $r 0 0]] head] [mkitsql::blobRead [lindex $r 0 0]]] {1 {} {} abc}
mkitsql::blobLimit -1
check whole_again [expr {[lindex [rows "SELECT data FROM img WHERE id = 3"] 0 0] eq $big}] 1
set ref [lindex $r 0 0]
store::closeFile $db
check stale_after_close [catch {mkitsql::blobRead $ref}] 1

rename ::mk::get {} ; rename ::mk::get_real ::mk::get
file delete $f
puts "blobs: $pass passed, $fail failed"
exit [expr {$fail ? 1 : 0}]
