set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_voice_state_bank_probe_20261026c]
file mkdir $out
set p [file join $out v2_voice_state_bank.gprj]
set f [open $p w]
puts $f {<?xml version="1.0"?><!DOCTYPE gowin-fpga-project><Project><Template>FPGA</Template><Version>5</Version><Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList><File path="../../rtl/v2_voice_state_bank.sv" type="file.verilog" enable="1"/><File path="../../sim/v2_voice_state_bank_probe.sv" type="file.verilog" enable="1"/><File path="../../mgc3130_v2_voice_probe.sdc" type="file.sdc" enable="1"/></FileList></Project>}
close $f
open_project $p
set_option -top_module v2_voice_state_bank_probe
set_option -verilog_std sysv2017
run syn
puts "V2_STATE_BANK_SYNTH_PASS"
run pnr
puts "V2_STATE_BANK_PNR_PASS"
exit
