`timescale 1ns/1ps
module tb_v2_voice_debug;
  logic clk=0,rst_n=0,sc=0,ev=0; logic [95:0] data; logic er; logic signed [15:0] mix; logic sv,ov; logic [31:0] bm; logic [7:0] rc; logic [5:0] ac;
  always #5 clk=~clk;
  v2_voice_engine_mux dut(.clk,.rst_n,.sample_ce(sc),.event_valid(ev),.event_ready(er),.event_data(data),.mixed_sample(mix),.sample_valid(sv),.active_bitmap(bm),.voice_overflow(ov),.revoice_count(rc),.active_voice_count(ac));
  task send(input [3:0] t,input [7:0] n); begin @(negedge clk); data=0; data[94:91]=t; data[71:64]=n; data[63:56]=100; ev=1; @(posedge clk); #1; $display("send t=%0d n=%0d ready=%b ac=%0d active=%h rc=%0d note0=%0d",t,n,er,ac,bm,rc,dut.note[0]); ev=0; end endtask
  initial begin repeat(2)@(posedge clk);rst_n=1;send(1,60);send(1,61);$display("before revoice note0=%0d active=%h ready=%b",dut.note[0],bm,er);send(3,60);$display("after revoice rc=%0d target0=%0d",rc,dut.target_a[0]);$finish;end
endmodule
