`timescale 1ns/1ps
module tb_v2_voice_engine_banked;
    logic clk=0, rst_n=0, sample_ce=0, event_valid=0;
    logic [95:0] event_data=0; logic event_ready;
    logic signed [15:0] mixed_sample; logic sample_valid;
    logic [31:0] active_bitmap; logic voice_overflow;
    logic [7:0] revoice_count; logic [15:0] voice_steal_count;
    logic [5:0] active_voice_count;
    logic [15:0] vibrato_hz_q8_8 = 16'd256;
    logic [15:0] vibrato_cents_q8_8 = 16'd3072;
    logic [15:0] vibrato_phase;
    logic signed [15:0] vibrato_delta_cents;
    integer i, samples;
    always #5 clk = ~clk;
    v2_voice_engine_banked #(.VOICES(32), .USE_GOWIN_RAM(0)) dut (.*);
    task automatic reset_dut;
      begin rst_n=0; event_valid=0; sample_ce=0; repeat(2) @(posedge clk); rst_n=1; @(negedge clk); end
    endtask
    task automatic send_event(input logic [3:0] typ, input logic [7:0] n, input logic signed [15:0] p, input logic [7:0] v);
      begin @(negedge clk); event_data=0; event_data[94:91]=typ; event_data[71:64]=n; event_data[63:56]=v; event_data[55:40]=p; event_valid=1; while(!event_ready) @(negedge clk); @(posedge clk); #1 event_valid=0; end
    endtask
    task automatic sample_once;
      integer w;
      begin @(negedge clk); sample_ce=1; @(posedge clk); #1 sample_ce=0; w=0; while(!sample_valid) begin @(posedge clk); w=w+1; if(w>100) $fatal(1,"sample timeout"); end end
    endtask
    initial begin
      reset_dut();
      send_event(1,60,0,255); if(active_voice_count!==1) $fatal(1,"one voice");
      for(i=1;i<32;i=i+1) send_event(1,60+i,0,255);
      if(active_voice_count!==32) $fatal(1,"32 voices");
      send_event(1,100,0,255);
      if(voice_overflow) $fatal(1,"full voice event incorrectly reported overflow");
      if(voice_steal_count !== 16'd1 || !dut.steal_pending || !dut.releasing[0])
        $fatal(1,"deterministic steal was not armed count=%0d pending=%b releasing=%b",
               voice_steal_count, dut.steal_pending, dut.releasing[0]);
      for(i=0;i<320;i=i+1) sample_once();
      if(!dut.active[0] || dut.note[0] !== 8'd100)
        $fatal(1,"stolen slot was not reused note=%0d active=%b pending=%b hold=%0d env=%0d scan_busy=%b slot=%0d",
               dut.note[0], dut.active[0], dut.steal_pending, dut.steal_hold[0],
               dut.rd_envelope, dut.scan_busy, dut.steal_slot_pending);
      if(vibrato_phase === 16'd0 || vibrato_delta_cents === 16'sd0)
        $fatal(1,"vibrato did not produce a readback phase/delta");
      send_event(2,100,0,0); samples=0;
      while(active_bitmap[0] && samples<100) begin sample_once(); samples=samples+1; end
      if(active_bitmap[0]) $fatal(1,"release");
      $display("tb_v2_voice_engine_banked PASS voices=%0d release_samples=%0d",active_voice_count,samples);
      $finish;
    end
endmodule
