# MK Studio's own row readers (::store::rows / fetch / fetchAt) must return rows intact on Tcl 8.5 / 8.6.3 even when the first
# cell is text starting with '#' with several ] or " (see docs/SQL.md, "Known bug in Tcl 8.5 and 8.6.3").  Run against a
# checkout that integration/mkstudio.patch has been applied to:
#   MKIT_MK4TCL=builtin MKSTUDIO_DIR=/path/to/patched/mkstudio tclkit/tclkit-8.6.3 tests/studio_listbug.tcl
set here [file dirname [file normalize [info script]]]
if {![info exists ::env(MKSTUDIO_DIR)]} { puts "set MKSTUDIO_DIR to a mkstudio checkout with integration/mkstudio.patch applied" ; exit 2 }
source $here/mk4load.tcl
source $::env(MKSTUDIO_DIR)/mkstudio.vfs/lib/app-mkstudio/store.tcl
set pass 0 ; set fail 0
proc check {n got want} { global pass fail ; if {$got eq $want} {incr pass} else {incr fail ; puts "FAIL $n\n  got:  [string map {\n NL} $got]\n  want: [string map {\n NL} $want]"} }
set f [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]/mkitsql_studio_lb_[pid].mk
file delete $f
set tag [store::openFile $f -create]
store::createView $tag t {{a S {}} {b S {}} {n I {}}}
set vals [list "#\]\]x" "#\]\]=\]a" "#\"q\" \"t\"" "#\]\]\]\]\]z" "plain" "#\{\}\]\]" "#\"\"" "#"]
set i 0
foreach v $vals { store::appendRow $tag.t {a b n} [list $v b$i $i] ; incr i }
store::commit $tag
# what a caller sees: the row's elements AND its string form (a row is often printed or compared as text); `canon` is the string a
# healthy Tcl writes for these values (the first element is braced because it starts with '#', or plain when it does not)
proc canon {v b n} { if {[string index $v 0] eq "#"} { return "\{$v\} $b $n" } ; return [list $v $b $n] }
proc flat {rows} { set o {} ; foreach r $rows { lappend o [llength $r] [lindex $r 0] [lindex $r 1] [lindex $r 2] [string range $r 0 end] } ; return $o }
set want {} ; set i 0 ; foreach v $vals { lappend want 3 $v b$i $i [canon $v b$i $i] ; incr i }
set lb [expr {[info exists ::store::listBug] ? $::store::listBug : "n/a - patch not applied"}]
check rows    [flat [store::rows $tag.t {a b n} 0 100]] $want
check fetch   [flat [store::fetch $tag.t {a b n} 0 100]] $want
set idx {} ; for {set k 0} {$k < [llength $vals]} {incr k} { lappend idx $k }
check fetchAt [flat [store::fetchAt $tag.t {a b n} $idx]] $want
# one property per row
set want1 {} ; foreach v $vals { lappend want1 1 $v [expr {[string index $v 0] eq "#" ? "\{$v\}" : $v}] }
proc flat1 {rows} { set o {} ; foreach r $rows { lappend o [llength $r] [lindex $r 0] [string range $r 0 end] } ; return $o }
check rows1   [flat1 [store::rows $tag.t {a} 0 100]] $want1
check fetch1  [flat1 [store::fetch $tag.t {a} 0 100]] $want1
store::closeFile $tag ; file delete $f
puts "studio list-bug checks: $pass passed, $fail failed (listBug: $lb)"
exit [expr {$fail ? 1 : 0}]
