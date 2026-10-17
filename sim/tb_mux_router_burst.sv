`timescale 1ns/1ps
module tb_mux_router_burst;
 import performance_event_pkg::*;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,flush=0,live_enable=1,record_enable=0,play_enable=0;
 reg [1:0] selected_track=0; reg [6:0] loop_tick=0; reg [19:0] store_record_count=0;
 reg live_valid=1; reg [63:0] live_data=0; wire live_ready;
 reg record_valid=0; reg [63:0] record_data=0; wire record_ready;
 wire routed_valid,routed_ready; wire [63:0] routed_data; wire mux_pending;
 reg sched_valid=0; reg [63:0] sched_data=0; reg kill_valid=0; wire sched_ready,kill_ready;
 reg live_in_valid=0,record_in_valid=0; reg [63:0] live_in_data=0,record_in_data=0;
 wire live_in_ready,record_in_ready;
 reg out_ready=1,write_ready=1; wire out_valid,write_valid; wire [63:0] out_data,write_data; wire [1:0] write_track; wire [3:0] write_slot; wire idle,record_accepted,record_overflow; wire [2:0] pending_debug;
 input_event_mux mux(.clk(clk),.rst_n(rst_n),.flush(flush),.live_valid(live_valid),.live_ready(live_ready),.live_data(live_data),.record_valid(record_valid),.record_ready(record_ready),.record_data(record_data),.out_valid(routed_valid),.out_ready(routed_ready),.out_data(routed_data),.pending_debug(mux_pending));
 performance_event_router router(.clk(clk),.rst_n(rst_n),.flush(flush),.live_enable(live_enable),.record_enable(record_enable),.play_enable(play_enable),.selected_track(selected_track),.loop_tick(loop_tick),.store_record_count(store_record_count),.in_valid(routed_valid),.in_ready(routed_ready),.in_data(routed_data),.sched_valid(sched_valid),.sched_ready(sched_ready),.sched_data(sched_data),.kill_valid(kill_valid),.kill_ready(kill_ready),.out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.write_valid(write_valid),.write_ready(write_ready),.write_track(write_track),.write_slot(write_slot),.write_data(write_data),.idle(idle),.record_accepted(record_accepted),.record_overflow(record_overflow),.pending_debug(pending_debug));
 integer accepts=0,outputs=0,cycles=0;
 always @(posedge clk) begin
  if(live_valid&&live_ready) accepts=accepts+1; if(out_valid&&out_ready) outputs=outputs+1; cycles=cycles+1;
  if(cycles==40) begin $display("muxrouter accepts=%0d outputs=%0d live_ready=%b mux_pending=%b routed=%b/%b router_pending=%b",accepts,outputs,live_ready,mux_pending,routed_valid,routed_ready,pending_debug); if(accepts<15||outputs<15)$fatal(1,"throughput"); $display("tb_mux_router_burst PASS");$finish;end
 end
 initial begin live_data[2:0]=EVENT_NOTE_ON; live_data[25:19]=60; repeat(3)@(negedge clk);rst_n=1;end
endmodule
