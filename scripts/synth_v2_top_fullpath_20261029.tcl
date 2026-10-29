# Canonical H0 full-path synthesis/P&R entry point.
#
# The PowerShell wrapper supplies V2_FULLPATH_RUN_ID.  A run directory is
# deliberately refused when it already exists, so a failed or stale artifact
# cannot be mistaken for evidence from a new source revision.
set root [file normalize [file join [file dirname [info script]] ..]]
if {[info exists ::env(V2_FULLPATH_RUN_ID)] && $::env(V2_FULLPATH_RUN_ID) ne ""} {
    set run_id $::env(V2_FULLPATH_RUN_ID)
} else {
    set run_id h0_manual
}
if {![regexp {^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$} $run_id]} {
    error "invalid V2_FULLPATH_RUN_ID: $run_id"
}
set out [file join $root impl "v2_top_fullpath_$run_id"]
if {[file exists $out]} {
    error "refusing to reuse existing output directory: $out"
}
file mkdir $out
set project [file join $out v2_top_fullpath.gprj]
set f [open $project w]
puts $f {<?xml version="1.0"?><!DOCTYPE gowin-fpga-project><Project><Template>FPGA</Template><Version>5</Version><Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>
<File path="../../ip/gowin_i2c_master/I2C_MASTER.vp" type="file.verilog" enable="1"/><File path="../../ip/gowin_i2c_master/I2C_MASTER_TOP.v" type="file.verilog" enable="1"/>
<File path="../../rtl/v2_contract_pkg.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_input_pkg.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_touch_info_decoder.sv" type="file.verilog" enable="1"/><File path="../../rtl/mgc3130_input_latch.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_input_calibration.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_position_validity.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_cursor_filter_timed.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_live_rule_engine.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_loop_event_recorder.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_loop_event_store_dpb.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_loop_scheduler.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_potts_commit_fsm.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_note_increment_rom.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_voice_state_bank.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_voice_engine_banked.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_fx_lite.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_patch_bank.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_wavetable_loader.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_clock_gen.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_reset_sync.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_sample_scheduler.sv" type="file.verilog" enable="1"/><File path="../../rtl/i2s_pcm5102a_tx.sv" type="file.verilog" enable="1"/><File path="../../rtl/uart_rx.sv" type="file.verilog" enable="1"/><File path="../../rtl/uart_tx.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_uart_link.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_telemetry_snapshot.sv" type="file.verilog" enable="1"/><File path="../../rtl/mgc3130_reader.sv" type="file.verilog" enable="1"/><File path="../../rtl/mgc3130_v2_top.sv" type="file.verilog" enable="1"/><File path="../../rtl/v2_test_mode.sv" type="file.verilog" enable="1"/>
<File path="../../sim/v2_top_fullpath_probe.sv" type="file.verilog" enable="1"/>
<File path="../../mgc3130_v2_top_observable.sdc" type="file.sdc" enable="1"/><File path="../../mgc3130_v2.cst" type="file.cst" enable="1"/>
</FileList></Project>}
close $f
open_project $project
set_option -top_module v2_top_fullpath_probe
set_option -verilog_std sysv2017
# E2 is the board oscillator and is multiplexed with CPU/SSPI functions.
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
puts "V2_FULLPATH_RUN_ID=$run_id"
puts "V2_FULLPATH_PROFILE=reader1,loop1,potts1,h32,fx1,fxlevel1"
puts "V2_FULLPATH_SYNTH_BEGIN"
run syn
puts "V2_FULLPATH_SYNTH_PASS"
puts "V2_FULLPATH_PNR_BEGIN"
run pnr
puts "V2_FULLPATH_PNR_PASS"
exit
