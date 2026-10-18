`timescale 1ns/1ps
module tb_mgc3130_voice_mixer;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,note_on=0,note_off=0,note_revoice=0,expression_valid=0; reg [6:0] note_number=48; reg [7:0] velocity=80;
 wire sample_valid; wire signed [15:0] mixed_sample; wire [2:0] active_voice_count;
 mgc3130_voice_mixer #(.CLK_HZ(1000),.SAMPLE_HZ(100)) dut(.*);
 task tick; begin @(posedge clk); #1; end endtask
 task wait_sample; begin while(sample_valid) tick; while(!sample_valid) tick; end endtask
 reg signed [15:0] positive_sample,negative_sample;
 reg [31:0] phase_before;
 initial begin
   repeat(2) tick; rst_n=1;
   note_on=1; tick; note_on=0; repeat(3) tick;
   if(active_voice_count>3) $fatal(1,"LIVE sound starts too many voices");
   // DDS phase steps must be scaled for sample-rate updates. The legacy
   // table was clock-rate based and would otherwise produce sub-hertz audio.
   wait_sample; phase_before=dut.phase_main;
   repeat(5) wait_sample;
   if ((dut.phase_main-phase_before) < 32'd100000)
     $fatal(1,"DDS phase step is still clock-rate scaled: before=%0d after=%0d",phase_before,dut.phase_main);
   expression_valid=1; velocity=120; tick; expression_valid=0;
   repeat(20) tick;
   // High LIVE pressure uses the full 8-bit range.  The waveform should vary
   // within a cycle instead of remaining a hard square wave.
   note_off=1; tick; note_off=0; tick;
   velocity=8'hff; note_on=1; tick; note_on=0;
   force dut.phase_main=32'h00000000; force dut.phase_aux=32'h00000000;
   wait_sample; positive_sample=mixed_sample;
   force dut.phase_main=32'h40000000; force dut.phase_aux=32'h40000000;
   wait_sample; negative_sample=mixed_sample;
   release dut.phase_main; release dut.phase_aux;
   if (positive_sample == negative_sample) $fatal(1,"waveform remains hard-square: %0d %0d",positive_sample,negative_sample);
   if (positive_sample == 16'sh7fff || positive_sample == -16'sh8000 ||
       negative_sample == 16'sh7fff || negative_sample == -16'sh8000)
     $fatal(1,"full pressure clipped before the output range: +%0d -%0d",positive_sample,negative_sample);
   note_revoice=1; note_number=60; velocity=100; tick; note_revoice=0;
   repeat(2) tick;
   if(active_voice_count>3) $fatal(1,"REVOICE creates too many voices");
   // Full pressure must remain below the output rails during the glide.
   note_off=1; tick; note_off=0; tick;
   velocity=8'hff; note_on=1; tick; note_on=0; tick;
   note_revoice=1; note_number=60; tick; note_revoice=0;
   force dut.phase_main=32'h00000000; force dut.phase_aux=32'h00000000;
   wait_sample;
   if (mixed_sample == 16'sh7fff || mixed_sample == -16'sh8000)
     $fatal(1,"six-voice full-pressure mix clipped: %0d",mixed_sample);
   release dut.phase_main; release dut.phase_aux;
   repeat(2500) tick;
   if(active_voice_count!=2) $fatal(1,"continuous voice unexpectedly disappeared during glide");
   note_off=1; tick; note_off=0; tick;
   if(active_voice_count!=0) $fatal(1,"NOTE_OFF was not hard");
   $display("tb_mgc3130_voice_mixer PASS"); $finish;
 end
 initial begin #100000; $fatal(1,"timeout"); end
endmodule
