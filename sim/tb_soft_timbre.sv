`timescale 1ns/1ps
module tb_soft_timbre;
  reg clk=0; always #1 clk=~clk;
  reg rst_n=0, note_on=0, note_off=0, expression_valid=0, soft_timbre=1;
  reg [6:0] note_number=60; reg [7:0] velocity=200;
  wire sample_valid; wire signed [15:0] mixed_sample; wire [2:0] active_voice_count;
  mgc3130_voice_mixer #(.CLK_HZ(1000),.SAMPLE_HZ(100),.ENV_SHIFT(2),.GLIDE_SHIFT(2)) dut(.*);
  integer samples=0, saturated=0, changed=0;
  reg signed [15:0] previous_sample;
  always @(posedge clk) if(sample_valid) begin
    samples=samples+1;
    if(mixed_sample==16'sh7fff || mixed_sample==-16'sh8000) saturated=saturated+1;
    if(samples>1 && (mixed_sample-previous_sample>12000 || previous_sample-mixed_sample>12000)) changed=changed+1;
    previous_sample=mixed_sample;
  end
  task pulse(input bit on_value,input bit off_value,input [6:0] n); begin
    @(negedge clk); note_on=on_value; note_off=off_value; note_number=n;
    @(negedge clk); note_on=0; note_off=0;
  end endtask
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    pulse(1,0,60); repeat(40) @(negedge clk);
    if(samples<3 || active_voice_count==0)$fatal(1,"soft timbre did not start");
    pulse(1,1,64); repeat(20) @(negedge clk);
    if(active_voice_count==0)$fatal(1,"soft glide inserted a hard release");
    if(changed>2)$fatal(1,"soft envelope/glide changed too abruptly");
    $display("tb_soft_timbre PASS"); $finish;
  end
  initial begin #10000; $fatal(1,"soft timbre timeout"); end
endmodule
