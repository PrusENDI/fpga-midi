set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_task9_fx_dpb_20261026]
file mkdir $out
set p [file join $out v2_task9_fx_dpb.gprj]
set f [open $p w]
puts $f {<?xml version="1.0"?><!DOCTYPE gowin-fpga-project><Project><Template>FPGA</Template><Version>5</Version><Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList><File path="../../rtl/v2_contract_pkg.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_wavetable_loader.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_patch_bank.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_fx_lite.sv" type="file.verilog" enable="1"/><File path="../../sim/v2_wavetable_fx_probe.sv" type="file.verilog" enable="1"/><File path="../../mgc3130_v2_task9.sdc" type="file.sdc" enable="1"/></FileList></Project>}
close $f
open_project $p
set_option -top_module v2_wavetable_fx_probe
set_option -verilog_std sysv2017
run syn
puts "V2_TASK9_FX_DPB_SYNTH_PASS"
run pnr
puts "V2_TASK9_FX_DPB_PNR_PASS"
exit
