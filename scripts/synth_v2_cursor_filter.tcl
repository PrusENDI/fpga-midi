# Standalone Task 4 synthesis only; no board project or P&R.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_cursor_synth]
file mkdir $out
set project [file join $out v2_cursor_filter.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach source {v2_input_pkg v2_cursor_filter} { puts $f "<File path=\"../../rtl/$source.sv\" type=\"file.verilog\" enable=\"1\"/>" }
puts $f {</FileList></Project>}; close $f
open_project $project
set_option -top_module v2_cursor_filter
set_option -verilog_std sysv2017
run syn
puts "V2_CURSOR_SYNTH_PASS: $out"
exit
