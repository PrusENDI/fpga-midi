# Task 8.5 standalone synthesis/resource probe.  This is deliberately not
# the final top and has no board pin constraints; its outputs are all exposed
# by v2_test_mode_synth_probe to prevent dead-code elimination.  The probe
# intentionally exposes the full CSR/status/sample interface (158 ports), so
# it is synthesis-only: this top cannot be placed on the 69-pin package.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_test_mode_synth_20261028]
file mkdir $out
set p [file join $out v2_test_mode.gprj]
set f [open $p w]
puts $f {<?xml version="1.0"?><!DOCTYPE gowin-fpga-project><Project><Template>FPGA</Template><Version>5</Version><Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList><File path="../../rtl/v2_contract_pkg.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_test_mode.sv" type="file.verilog" enable="1"/><File path="../../sim/v2_test_mode_synth_probe.sv" type="file.verilog" enable="1"/><File path="../../mgc3130_v2_test_mode.sdc" type="file.sdc" enable="1"/></FileList></Project>}
close $f
open_project $p
set_option -top_module v2_test_mode_synth_probe
set_option -verilog_std sysv2017
run syn
puts "V2_TEST_MODE_SYNTH_PASS"
exit
