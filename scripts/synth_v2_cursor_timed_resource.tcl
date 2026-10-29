# Standalone diagnostic only. GOWIN_CURSOR_REF may select immutable git RTL.
set root [file normalize [file join [file dirname [info script]] ..]]
set tag [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set out [file join $root impl cursor_resource_$tag]
file mkdir $out
set source [file join $root rtl v2_cursor_filter_timed.sv]
if {[info exists ::env(GOWIN_CURSOR_REF)] && $::env(GOWIN_CURSOR_REF) ne ""} {
  set text [exec git -C $root show "$::env(GOWIN_CURSOR_REF):rtl/v2_cursor_filter_timed.sv"]
  set source [file join $out selected.sv]
  set f [open $source w]; puts $f $text; close $f
}
set project [file join $out cursor.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach path [list [file join $root rtl v2_input_pkg.sv] $source] {
  puts $f "<File path=\"$path\" type=\"file.verilog\" enable=\"1\"/>"
}
puts $f {</FileList></Project>}; close $f
open_project $project
set_option -top_module v2_cursor_filter_timed
set_option -verilog_std sysv2017
run syn
puts "CURSOR_RESOURCE_SYNTH_PASS source=$source out=$out"
exit
