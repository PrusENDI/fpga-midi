# Isolated synthesis: leave board project output and bitstream untouched.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl control_plane_synth]
file mkdir $out
set project [file join $out control_plane.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach source {control_protocol_pkg performance_event_pkg loop_event_ram loop_event_store loop_scheduler command_mailbox control_csr mode_manager performance_event_router input_event_mux loop_control_plane} {
    puts $f "<File path=\"../../rtl/$source.sv\" type=\"file.verilog\" enable=\"1\"/>"
}
puts $f {</FileList></Project>}
close $f
open_project $project
set_option -top_module loop_control_plane
set_option -verilog_std sysv2017
run syn
puts "CONTROL_PLANE_SYNTH_PASS: $out"
exit
