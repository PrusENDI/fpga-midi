# Standalone input logic synthesis, without changing the board bitstream.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl input_adapter_synth]
file mkdir $out
set project [file join $out input_adapter.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach source {performance_event_pkg control_protocol_pkg input_event_adapter} {
    puts $f "<File path=\"../../rtl/$source.sv\" type=\"file.verilog\" enable=\"1\"/>"
}
puts $f {</FileList></Project>}
close $f
open_project $project
set_option -top_module input_event_adapter
set_option -verilog_std sysv2017
run syn
puts "INPUT_ADAPTER_SYNTH_PASS: $out"
exit
