set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_loop_transactions_probe_20261027]
file mkdir $out
set project [file join $out v2_loop_transactions_probe.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach source {v2_contract_pkg v2_loop_event_store_dpb v2_loop_scheduler} {
  puts $f "<File path=\"../../rtl/$source.sv\" type=\"file.verilog\" enable=\"1\"/>"
}
puts $f {<File path="../../sim/v2_loop_transactions_probe.sv" type="file.verilog" enable="1"/>}
puts $f {<File path="../../mgc3130_v2_loop_transactions_probe.cst" type="file.cst" enable="1"/>}
puts $f {<File path="../../mgc3130_v2_loop_transactions_probe.sdc" type="file.sdc" enable="1"/>}
puts $f {</FileList></Project>}
close $f
open_project $project
set_option -top_module v2_loop_transactions_probe
set_option -verilog_std sysv2017
run syn
puts "V2_LOOP_TRANSACTIONS_SYNTH_PASS: $out"
run pnr
puts "V2_LOOP_TRANSACTIONS_PNR_PASS: $out"
exit
