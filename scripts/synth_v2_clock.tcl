set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_clock_synth]
file mkdir $out
set project [file join $out v2_clock.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach source {v2_clock_gen v2_sample_scheduler} {
    puts $f "<File path=\"../../rtl/$source.sv\" type=\"file.verilog\" enable=\"1\"/>"
}
puts $f {</FileList></Project>}
close $f
open_project $project
set_option -top_module v2_clock_gen
set_option -verilog_std sysv2017
run syn
puts "V2_CLOCK_SYNTH_PASS: $out"
exit
