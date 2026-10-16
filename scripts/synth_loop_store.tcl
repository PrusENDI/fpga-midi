# Standalone synthesis only: does not change the board project or bitstream.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl loop_store_synth]
file mkdir $out
set project [file join $out loop_store.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
puts $f {<File path="../../rtl/loop_event_ram.sv" type="file.verilog" enable="1"/>}
puts $f {<File path="../../rtl/loop_event_store.sv" type="file.verilog" enable="1"/>}
puts $f {</FileList></Project>}
close $f
open_project $project
set_option -top_module loop_event_store
set_option -verilog_std sysv2017
run syn
puts "LOOP_STORE_SYNTH_PASS: $out"
exit
