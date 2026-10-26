set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_input_arithmetic_synth]
file mkdir $out
set project [file join $out v2_input_arithmetic.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach source {v2_input_pkg v2_input_calibration v2_position_validity v2_input_arithmetic_probe} { puts $f "<File path=\"../../rtl/$source.sv\" type=\"file.verilog\" enable=\"1\"/>" }
puts $f {</FileList></Project>}; close $f
open_project $project
set_option -top_module v2_input_arithmetic_probe
set_option -verilog_std sysv2017
# The probe exposes registered calibration/quality outputs as top-level pins
# and marks both datapath instances with keep_hierarchy attributes.  Keep the
# synthesis report as the preservation evidence; no P&R is requested here.
run syn
puts "V2_INPUT_ARITH_SYNTH_PASS: $out"
exit
