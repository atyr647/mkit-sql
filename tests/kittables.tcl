# The virtual-table registry (vtab.tcl) and its first user, the kit.* tables (kit.tcl), on REAL Metakit:
#   MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/kittables.tcl        (MKIT_BACKEND as for the other tests)
# The kits are Ribbon's golden test kits and the reader is Ribbon's kitfmt, both pinned in tests/vendor/kitfmt
# (tests/sync-kitfmt.sh; SOURCE names the commit).  KITFMT_DIR=<dir> reads with another copy of kitfmt instead (CI: the one MK
# Studio carries); the golden kits stay the pinned ones.
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(MKIT_MK4TCL)] || $::env(MKIT_MK4TCL) eq ""} { puts "set MKIT_MK4TCL to the Mk4tcl shared library, or to 'builtin' inside a tclkit" ; exit 2 }
source $here/mk4load.tcl
source $here/loadengine.tcl
set kitfmtDir [expr {[info exists ::env(KITFMT_DIR)] && $::env(KITFMT_DIR) ne "" ? $::env(KITFMT_DIR) : "$here/vendor/kitfmt"}]
if {![file exists $kitfmtDir/kitfmt.tcl]} { puts "no kitfmt.tcl in $kitfmtDir" ; exit 2 }
lappend auto_path $kitfmtDir
set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_kit_[pid]
file delete -force $tmp ; file mkdir $tmp
set pass 0 ; set fail 0
proc chk {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string range $got 0 400]\n  want: $want"} }
proc rows {sql {db ""}} { if {$db eq ""} { set db $::db } ; dict get [mkitsql::run $sql $db] rows }
proc err {sql {db ""}} { if {$db eq ""} { set db $::db } ; if {[catch {mkitsql::run $sql $db} m]} { return $m } ; return "(no error)" }
proc slurp {f} { set h [open $f rb] ; set d [read $h] ; close $h ; return $d }

# ---- the registry --------------------------------------------------------------------------------------------------------
set plain $tmp/plain.mk
set db [store::openFile $plain -create]
mkitsql::run "CREATE TABLE t (id INT, name VARCHAR)" $db
mkitsql::run "INSERT INTO t VALUES (1, 'one'), (2, 'two')" $db
proc ::demoRows {ctx} {
    set ::lastCtx $ctx
    return [list [list 1 alpha 1.5] [list 2 beta ""] [list 3 "bad\uFDD0NULL" 2]]
}
mkitsql::registerVirtual demo items {{id int} {label text} {score real}} ::demoRows
chk vt_select [rows "SELECT id, label FROM demo.items WHERE id < 3 ORDER BY id DESC"] {{2 beta} {1 alpha}}
chk vt_null [rows "SELECT COUNT(*) FROM demo.items WHERE score IS NULL"] 1
chk vt_ctx [list [dict get $::lastCtx schema] [dict get $::lastCtx table] [dict get $::lastCtx db]] [list demo items $db]
chk vt_no_forged_null [rows "SELECT COUNT(*) FROM demo.items WHERE label IS NULL"] 0
chk vt_join [rows "SELECT t.name, d.label FROM t JOIN demo.items d ON d.id = t.id ORDER BY t.id"] {{one alpha} {two beta}}
chk vt_subquery [rows "SELECT name FROM t WHERE id IN (SELECT id FROM demo.items WHERE score < 1.6)"] one
chk vt_unknown [err "SELECT * FROM demo.nope"] "Unknown demo table 'nope'.  Available: items"
chk vt_readonly [string match "*demo*" [err "DELETE FROM demo.items"]] 1
chk vt_list [mkitsql::virtualTables demo] {{demo items {{id int} {label text} {score real}}}}
chk vt_bad_name [catch {mkitsql::registerVirtual "a b" t {{x int}} list}] 1
chk vt_bad_type [catch {mkitsql::registerVirtual demo t2 {{x date}} list}] 1
chk vt_dup_col [catch {mkitsql::registerVirtual demo t2 {{x int} {X text}} list}] 1
proc ::wideRows {ctx} { return {{1 2 3 4}} }
mkitsql::registerVirtual demo wide {{a int} {b int}} ::wideRows
chk vt_width [err "SELECT * FROM demo.wide"] "demo.wide: a row has 4 values for 2 columns"
proc ::badRows {ctx} { error "the provider broke" }
mkitsql::registerVirtual demo broken {{a int}} ::badRows
chk vt_error [err "SELECT * FROM demo.broken"] "demo.broken: the provider broke"
proc ::notInt {ctx} { return {{x}} }
mkitsql::registerVirtual demo notint {{a int}} ::notInt
chk vt_type_checked [err "SELECT * FROM demo.notint"] "demo.notint: 'x' in an int column"
mkitsql::unregisterVirtual demo
chk vt_unregistered [err "SELECT * FROM demo.items"] "Unknown database 'demo'. Open databases: plain"
# a schema named like an open database never hides the database's tables
mkitsql::registerVirtual plain t {{x int}} {apply {{ctx} { return {{42}} }}}
chk vt_db_wins [rows "SELECT name FROM plain.t ORDER BY id"] {one two}
mkitsql::unregisterVirtual plain
# information_schema goes through the registry now, and still works as before
chk info_schema [rows "SELECT table_name, row_count FROM information_schema.tables"] {{t 2}}
chk info_columns [rows "SELECT column_name, data_type FROM information_schema.columns ORDER BY ordinal_position"] {{id INTEGER} {name VARCHAR}}
chk info_unknown [err "SELECT * FROM information_schema.nope"] "Unknown information_schema table 'nope'.  Available: columns, tables"
chk explain_names_it [string match "*information_schema.tables*" [rows "EXPLAIN SELECT * FROM information_schema.tables"]] 1
chk kit_not_a_kit [err "SELECT * FROM kit.info"] "kit.info: no open database is a kit"
store::closeFile $db

# ---- the kit.* tables -------------------------------------------------------------------------------------------------------
foreach k {app system bad-chunk} { file copy $here/vendor/kitfmt/golden/$k.kit $tmp/$k.kit }
set before [slurp $tmp/app.kit]
set db [store::openFile $tmp/app.kit -readonly]
chk kit_info [rows "SELECT value FROM kit.info WHERE key IN ('kind', 'name', 'version', 'root_state', 'format') ORDER BY key"] {1.0 app org.ribbon.golden.app ok 1.2.0}
chk kit_signer [rows "SELECT value FROM kit.info WHERE key = 'signer'"] CF096CB575EDBA78
chk kit_manifest [rows "SELECT value FROM kit.manifest WHERE key = 'license'"] MIT
chk kit_needs [rows "SELECT name, range FROM kit.needs ORDER BY name"] {{org.ribbon.runtime.tcl >=8.6} {org.ribbon.runtime.tk >=8.6}}
chk kit_perms [rows "SELECT value FROM kit.perms WHERE name = 'display'"] wayland
chk kit_entries [rows "SELECT name, path, type FROM kit.entries ORDER BY name"] {{hello bin/hello app} {main main.tcl cli}}
chk kit_effects [rows "SELECT COUNT(*) FROM kit.effects"] 2
chk kit_files [rows "SELECT path, size, codec, chunks, stored FROM kit.files WHERE type = 'file' ORDER BY size DESC LIMIT 2"] {{lib/big.txt 46342 deflate 3 6703} {lib/noise.bin 3000 raw 1 3000}}
chk kit_dirs [rows "SELECT path FROM kit.files WHERE type = 'dir' AND size IS NULL ORDER BY path"] {bin docs lib share share/applications share/icons}
chk kit_link [rows "SELECT path, link FROM kit.files WHERE type = 'link'"] {{lib/hello-link ../bin/hello}}
chk kit_modes [rows "SELECT mode, date FROM kit.files WHERE path = 'bin/hello'"] {{493 1700000000}}
chk kit_chunks [rows "SELECT COUNT(*), SUM(stored) FROM kit.chunks"] {{9 10524}}
chk kit_chunks_join [rows "SELECT f.path, COUNT(c.idx) FROM kit.files f JOIN kit.chunks c ON c.path = f.path GROUP BY f.path HAVING COUNT(c.idx) > 1"] {{lib/big.txt 3}}
chk kit_hash [regexp {^[0-9a-f]{64}$} [rows "SELECT hash FROM kit.chunks WHERE path = 'lib/big.txt' AND idx = 2"]] 1
chk kit_image_none [rows "SELECT COUNT(*) FROM kit.image"] 0
chk kit_verify [rows "SELECT part, path, ok FROM kit.verify WHERE part <> 'file' ORDER BY part"] {{header {} 1} {root {} 1} {signature {} 0}}
chk kit_verify_files [rows "SELECT COUNT(*), MIN(ok) FROM kit.verify WHERE part = 'file'"] {{8 1}}
chk kit_raw_views [rows "SELECT COUNT(*) FROM dirs"] 7
store::closeFile $db
chk kit_untouched [expr {[slurp $tmp/app.kit] eq $before}] 1
chk kit_no_side_files [lsort [glob -tails -directory $tmp *]] {app.kit bad-chunk.kit plain.mk system.kit}

set db [store::openFile $tmp/system.kit -readonly]
chk kit_image [rows "SELECT fs, file_offset, length, segments FROM kit.image"] {{erofs 8192 16384 1}}
chk kit_image_aligned [rows "SELECT file_offset % 4096 FROM kit.image"] 0
chk kit_system_verify [rows "SELECT part, ok FROM kit.verify WHERE part IN ('image', 'root')  ORDER BY part"] {{image 1} {root 1}}
set sys $db
set db2 [store::openFile $tmp/bad-chunk.kit -readonly]
chk kit_bad_chunk [rows "SELECT path, ok FROM kit.verify WHERE ok = 0 AND part = 'file'" $db2] {{lib/big.txt 0}}
chk kit_bad_detail [string match "*chunk 1 does not match its hash*" [rows "SELECT detail FROM kit.verify WHERE path = 'lib/big.txt'" $db2]] 1
# the statement's default database decides which kit; with two kits open and no default it is ambiguous
chk kit_default_db [rows "SELECT value FROM kit.info WHERE key = 'kind'" $sys] system
chk kit_ambiguous [string match "*more than one open database is a kit*" [err "SELECT * FROM kit.info" "nosuchdb"]] 1
store::closeFile $db2
store::closeFile $sys

# without kitfmt the tables say what is missing (a child process that has no kitfmt on its auto_path)
set child $tmp/child.tcl
set ch [open $child w]
puts $ch [list set here $here]
puts $ch {
    source $here/mk4load.tcl
    source $here/loadengine.tcl
    set db [store::openFile [lindex $argv 0] -readonly]
    catch {mkitsql::run "SELECT * FROM kit.info" $db} m
    puts $m
    exit 0
}
close $ch
set out [exec [info nameofexecutable] $child $tmp/app.kit 2>@1]
chk kit_needs_kitfmt [string match "*the kit.* tables need the kitfmt package*" $out] 1

mkitsql::kit::forget
file delete -force $tmp
chk kitfmt_is_the_one_asked_for [expr {[info exists ::kitfmt::dir] && [file normalize $::kitfmt::dir] eq [file normalize $kitfmtDir]}] 1
puts "kit tables: $pass passed, $fail failed (kitfmt from $kitfmtDir)"
exit [expr {$fail ? 1 : 0}]
