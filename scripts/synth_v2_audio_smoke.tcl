set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root impl v2_audio_smoke_20261027]
file mkdir $out
set project [file join $out v2_audio_smoke.gprj]
set f [open $project w]
puts $f {<?xml version="1.0" encoding="UTF-8"?>}
puts $f {<!DOCTYPE gowin-fpga-project>}
puts $f {<Project><Template>FPGA</Template><Version>5</Version>}
puts $f {<Device name="GW5A-25A" pn="GW5A-LV25MG121NES">gw5a25a-000</Device><FileList>}
foreach source {v2_clock_gen v2_reset_sync v2_sample_scheduler i2s_pcm5102a_tx v2_audio_smoke_top} {
    puts $f "<File path=\"../../rtl/$source.sv\" type=\"file.verilog\" enable=\"1\"/>"
}
puts $f {<File path="../../mgc3130_v2_audio_smoke.cst" type="file.cst" enable="1"/>}
puts $f {<File path="../../mgc3130_v2_audio_smoke.sdc" type="file.sdc" enable="1"/>}
puts $f {</FileList></Project>}
close $f
open_project $project
set_option -top_module v2_audio_smoke_top
set_option -verilog_std sysv2017
run syn
puts "V2_AUDIO_SMOKE_SYNTH_PASS: $out"
run pnr
puts "V2_AUDIO_SMOKE_PNR_PASS: $out"
exit
