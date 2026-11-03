# dbcheck.tcl -- is this file an intact Metakit database?  (used by both storage layers before opening)
#
# Mk4tcl will "open" ANY file: a truncated database, one with a damaged header or footer, or a text file all look
# like a database with no tables - and writing into it and committing would REPLACE the original.  A committed Metakit
# file has a fixed frame, which is cheap to verify without reading the data:
#
#   header  (8 bytes)  "JL" (or "LJ" for the other byte order), 0x1A, 0x00, then the file's size as one 32-bit word
#   footer (16 bytes)  word 0x80000000, the offset of the footer itself (= size - 16), word 0x80<len>, the offset of the table
#
# What this cannot see: bytes flipped inside the data (Metakit stores no checksums).  Files that do not start with the
# signature (a starkit / starpack carries its database at the end) are not judged here: the opener refuses them only if
# they hold no tables at all.
namespace eval ::mkitsql {}

# "" if the file looks intact (or is empty/new), otherwise the reason it is not
proc ::mkitsql::dbProblem {path} {
    if {![file exists $path]} { return "" }
    set size [file size $path]
    if {$size == 0} { return "" }
    if {[catch {
        set h [open $path rb]
        set head [read $h 8]
        seek $h [expr {$size > 16 ? -16 : 0}] end
        set tail [read $h 16]
        close $h
    } msg]} { return "it cannot be read ($msg)" }
    set sig [string range $head 0 1]
    if {$sig ne "JL" && $sig ne "LJ"} { return "" }              ;# not a standalone database file: judged after opening
    if {$size < 24} { return "it is too short to be a Metakit database ($size bytes)" }
    set fmt [expr {$sig eq "JL" ? "I" : "i"}]                    ;# JL: words are big-endian, LJ: little-endian
    binary scan $head x4$fmt hdrSize
    binary scan $tail $fmt$fmt$fmt$fmt w0 footPos w2 tocPos
    set hdrSize [expr {$hdrSize & 0xFFFFFFFF}] ; set footPos [expr {$footPos & 0xFFFFFFFF}] ; set tocPos [expr {$tocPos & 0xFFFFFFFF}]
    set flag0 [expr {($w0 >> 24) & 0xFF}] ; set flag2 [expr {($w2 >> 24) & 0xFF}]
    if {$hdrSize > $size} { return "it is truncated: the header says $hdrSize bytes but the file has only $size" }
    if {$hdrSize < $size} { return "the header says $hdrSize bytes but the file has $size (it was cut or extended by another program)" }
    if {$flag0 != 0x80 || $flag2 != 0x80} { return "its footer is damaged" }
    if {$footPos != $size - 16} { return "its footer is not where the header says it should be" }
    if {$tocPos >= $footPos} { return "its table of contents lies outside the file" }
    return ""
}
# raise MKIT DAMAGED unless the file is intact
proc ::mkitsql::dbRequireIntact {path} {
    set why [dbProblem $path]
    if {$why ne ""} {
        return -code error -errorcode [list MKIT DAMAGED $why] \
            "This file does not look like an intact Metakit database ($why):\n$path\nOpening it would show an empty database, and saving would overwrite it. Open a backup, or pass -unchecked to open it anyway."
    }
}
# after a successful open: a non-empty file without the Metakit signature and with no tables is some other kind of file
proc ::mkitsql::dbSignatureOk {path hasViews} {
    if {$hasViews || ![file exists $path] || [file size $path] == 0} { return 1 }
    if {[catch {set h [open $path rb] ; set sig [read $h 2] ; close $h}]} { return 1 }
    return [expr {$sig eq "JL" || $sig eq "LJ"}]
}
