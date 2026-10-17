`timescale 1ns/1ps
module tb_router_burst;
 import performance_event_pkg::*;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,flush=0,live_enable=1,record_enable=0,play_enable=0;
 reg [1:0] selected_track=0; reg [6:0] loop_tick=0; reg [19:0] store_record_count=0;
 reg in_valid=1; reg [63:0] in_data=0; reg sched_valid=0; reg [63:0] sched_data=0;
 reg live_in_valid=0,record_in_valid=0; reg [63:0] live_in_data=0,record_in_data=0;
 wire live_in_ready,record_in_ready;
 reg kill_valid=0; reg out_ready=1; reg write_ready=1;
 wire in_ready,sched_ready,kill_ready,out_valid,write_valid,idle,record_accepted,record_overflow;
 wire [63:0] out_data,write_data; wire [1:0] write_track; wire [3:0] write_slot; wire [2:0] pending_debug;
 performance_event_router dut(.*);
 integer accepts=0,outputs=0,cycles=0;
 always @(posedge clk) begin
   if(in_valid && in_ready) accepts=accepts+1;
   if(out_valid && out_ready) outputs=outputs+1;
   cycles=cycles+1;
   if(cycles==40) begin
     $display("burst accepts=%0d outputs=%0d in_ready=%b out_valid=%b pending=%b",accepts,outputs,in_ready,out_valid,pending_debug);
     if(accepts < 18 || outputs < 18) $fatal(1,"router throughput too low");
     $display("tb_router_burst PASS"); $finish;
   end
 end
 initial begin
   in_data[2:0]=EVENT_NOTE_ON; in_data[25:19]=7'd60;
   repeat(3) @(negedge clk); rst_n=1;
 end
endmodule
