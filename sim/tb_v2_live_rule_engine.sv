`timescale 1ns/1ps
module tb_v2_live_rule_engine;
  import v2_contract_pkg::*;
  logic clk=0,rst_n=0,frame_in_valid=0,frame_valid=1,frame_degraded=0,frame_gap=0,rebased=0,left_edge=0;
  logic [15:0] x=0,y=0,z=0; logic touch=0,bow=1; logic [31:0] tick=0;
  logic [7:0] velocity_in=90; logic [15:0] brightness_in=0,gain_in=0;
  logic event_valid,event_ready=1; logic [95:0] event_data; logic [3:0] event_type;
  logic [7:0] event_note,event_velocity; logic [15:0] event_count; logic [7:0] fault_code;
  logic left_edge_armed,gate_state,active; logic [7:0] active_note;
  logic [95:0] held_event; logic [15:0] held_count; logic held_active; logic [7:0] held_note;
  always #5 clk=~clk;
  v2_live_rule_engine #(.MIN_EVENT_TICKS(4),.GATE_TOUCH(1)) dut(.*);
  task automatic send(input integer xx,input integer yy,input integer zz,input integer tt,input logic edge_flag,input logic tv);
    begin @(negedge clk); x=xx; y=yy; z=zz; tick=tt; left_edge=edge_flag; touch=tv; frame_in_valid=1;
      @(posedge clk); #1; @(negedge clk); frame_in_valid=0; left_edge=0; end
  endtask
  initial begin
    repeat(2) @(posedge clk); rst_n=1;
    send(0,0,100,0,1,1); if(event_valid||left_edge_armed) $fatal(1,"left edge must wait for right confirmation");
    send(6000,0,100,1,0,1); if(!event_valid||event_type!==1||!left_edge_armed) $fatal(1,"right confirm note on");
    @(posedge clk); #1; if(event_valid) $fatal(1,"event did not drain");
    send(1000,10000,100,1,0,1); if(event_valid) $fatal(1,"minimum tick violated");
    // A pending event must retain its word and state while the consumer is stalled.
    @(negedge clk); event_ready=0; x=6000; y=12000; z=100; tick=5; left_edge=0; touch=1; frame_in_valid=1;
    @(posedge clk); #1; if(!event_valid || event_type!==V2_EV_REVOICE) $fatal(1,"stalled revoice was not queued");
    held_event=event_data; held_count=event_count; held_active=active; held_note=active_note;
    @(negedge clk); frame_in_valid=0; @(posedge clk); #1;
    if(!event_valid || event_data!==held_event || event_count!==held_count || active!==held_active || active_note!==held_note) $fatal(1,"pending event changed under backpressure");
    @(negedge clk); event_ready=1; @(posedge clk); #1; if(event_valid) $fatal(1,"pending event did not drain");
    @(posedge clk); #1;
    send(6000,12000,200,6,0,1); if(!event_valid||event_type!==4) $fatal(1,"pure z control");
    @(posedge clk); #1; send(6000,12000,200,10,0,0); if(!event_valid||event_type!==2) $fatal(1,"touch off");
    @(posedge clk); #1; frame_valid=0; send(20000,30000,100,7,0,1); if(event_valid) $fatal(1,"invalid note event");
    $display("tb_v2_live_rule_engine PASS"); $finish;
  end
endmodule
