`timescale 1ns/1ps
module tb_performance_event_router;
 import performance_event_pkg::*;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,flush=0,live_enable=1,record_enable=1,play_enable=1;
 reg [1:0]selected_track=2;reg[6:0]loop_tick=37;reg[19:0]store_record_count=20'd3072;
 reg in_valid=0,sched_valid=0,kill_valid=0,out_ready=0,write_ready=0;
 reg[63:0]in_data=0,sched_data=0;
 wire in_ready,sched_ready,kill_ready,out_valid,write_valid,idle,record_accepted,record_overflow;
 wire[63:0]out_data,write_data;wire[1:0]write_track;wire[3:0]write_slot;
 performance_event_router dut(.*);
 integer outputs=0,writes=0,pulses=0;
 reg[63:0]got[0:31];
 always @(posedge clk)begin
  if(out_valid&&out_ready)begin got[outputs]=out_data;outputs=outputs+1;end
  if(write_valid&&write_ready)writes=writes+1;
 end
 always @(negedge clk)if(record_accepted)pulses=pulses+1;
 task cycles(input integer count);repeat(count)@(negedge clk);endtask
 task send(input[63:0]data);begin
  @(negedge clk);in_data=data;in_valid=1;do @(posedge clk);while(!in_ready);
  @(negedge clk);in_valid=0;
 end endtask
 reg[63:0]held;integer old_outputs,old_writes;
 initial begin
  cycles(3);rst_n=1;
  send(64'h0123456789abc000);cycles(3);
  if(!write_valid || write_track!=2 || write_slot!=3 || write_data!==64'h0123456789abc4b0)$fatal(1,"record snapshot");
  if(!out_valid || out_data!==64'h0123456789abc010)$fatal(1,"monitor track override");
  held=write_data;selected_track=1;loop_tick=55;store_record_count=0;live_enable=0;record_enable=0;
  out_ready=1;cycles(4);
  if(outputs!=1 || writes!=0 || !write_valid || write_data!==held || in_ready)$fatal(1,"independent monitor completion");
  write_ready=1;cycles(3);if(writes!=1 || pulses!=1 || !idle)$fatal(1,"record completion");
  // Opposite branch stall must not duplicate a completed write.
  live_enable=1;record_enable=1;out_ready=0;
  send(64'h0000000000000001);cycles(5);
  if(writes!=2 || !out_valid)$fatal(1,"independent store completion");
  held=out_data;kill_valid=1;sched_valid=1;sched_data=64'h1234567800000002;
  cycles(4);if(out_data!==held || kill_ready || sched_ready)$fatal(1,"stalled output changed");
  out_ready=1;@(posedge clk);@(negedge clk);kill_valid=0;
  cycles(3);sched_valid=0;cycles(2);
  if(got[1]!==held || got[2][2:0]!==EVENT_ALL_NOTES_OFF || got[3]!==64'h1234567800000002)$fatal(1,"output arbitration order");
  // Full track drops only record copy; no wraparound write/deadlock.
  store_record_count=20'd512;old_writes=writes;old_outputs=outputs;
  send(0);cycles(6);
  if(!record_overflow || writes!=old_writes || outputs!=old_outputs+1 || !idle)$fatal(1,"full capacity behavior");
  // Flush cancels stalled event and recording, then kill can enter a clean output.
  store_record_count=0;out_ready=0;write_ready=0;send(0);cycles(3);
  flush=1;in_valid=1;sched_valid=1;kill_valid=1;#1;
  if(out_valid || write_valid || in_ready || sched_ready || kill_ready)$fatal(1,"flush gating");
  cycles(2);in_valid=0;sched_valid=0;flush=0;#1;
  if(record_overflow || out_valid || write_valid)$fatal(1,"flush clearing");
  @(posedge clk);@(negedge clk);kill_valid=0;
  if(!out_valid || out_data[2:0]!==EVENT_ALL_NOTES_OFF)$fatal(1,"postflush kill");
  out_ready=1;cycles(2);
  // Muted playback drains scheduler even with output occupied.
  play_enable=0;out_ready=0;kill_valid=1;cycles(1);kill_valid=0;
  sched_valid=1;#1;if(!sched_ready)$fatal(1,"muted scheduler deadlock");
  cycles(4);sched_valid=0;out_ready=1;cycles(3);
  // Non-note/control metadata is monitored, never recorded.
  old_writes=writes;send(64'd5);cycles(4);if(writes!=old_writes)$fatal(1,"recorded unsupported event");
  // A completed duration tail is storage-only and remains accepted after
  // record_enable/live_enable have been withdrawn for COMMIT_PENDING.
  live_enable=0;record_enable=0;store_record_count=0;write_ready=1;out_ready=1;old_outputs=outputs;
  in_data=64'd0;in_data[2:0]=EVENT_NOTE_ON;in_data[4:3]=2'd1;in_data[11:5]=7'd9;
  in_data[18:12]=7'd4;in_data[25:19]=7'd60;in_data[61]=1'b1;
  in_valid=1;cycles(2);in_valid=0;cycles(2);
  if(writes!=old_writes+1 || outputs!=old_outputs || !idle)$fatal(1,"record tail drain");
  $display("tb_performance_event_router PASS");$finish;
 end
 initial begin #100000;$fatal(1,"router timeout");end
endmodule
