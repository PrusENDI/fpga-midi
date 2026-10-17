`timescale 1ns/1ps
module tb_live_note_gate;
 import control_protocol_pkg::*;
 import performance_event_pkg::*;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0, report_valid=0, xyz_valid=1, report_error=0;
 reg [15:0] x_position=16'h1000, y_position=16'h1000, z_position=16'h8000;
 reg touch_valid=0; reg [31:0] touch_info=0;
 reg presence_valid=0, present=1;
 reg [3:0] mode=MODE_LIVE; reg [1:0] selected_track=0;
 reg [6:0] loop_tick=0; reg [15:0] start_enter=16'h2000,start_exit=16'h3000;
 reg flush=0, live_ready=1, record_ready=1, modulation_ready=1, record_start_ready=1;
 wire live_valid,record_valid,modulation_valid,record_start,idle,overflow;
 wire [63:0] live_event,record_event,modulation_event;
 input_event_adapter #(.NOTE_CONFIRM(1),.CELL_CONFIRM(2),.COORD_FILTER_SHIFT(0),
   .LIVE_X_TRIGGER_CONFIRM(2),.LIVE_X_TRIGGER_DISTANCE(16'h0e00),
   .LIVE_Y_MIN(16'h1700),.LIVE_Y_MAX(16'he900),
   .LIVE_Z_PRESS_CONFIRM(1),.LIVE_Z_RELEASE_CONFIRM(1),
   .LIVE_Z_PRESS_THRESHOLD(16'ha000),.LIVE_Z_RELEASE_THRESHOLD(16'he000),
   .TIMEOUT_CYCLES(1000)) dut(.*);
 integer ons=0; reg [6:0] last_note=0;
 always @(posedge clk) if(live_valid && live_ready && live_event[2:0]==EVENT_NOTE_ON) begin
   ons=ons+1; last_note=live_event[25:19];
 end
 task report(input [15:0] x,input [15:0] y); begin
   @(negedge clk); x_position=x; y_position=y; report_valid=1;
   @(posedge clk); #1; @(negedge clk); report_valid=0; repeat(2) @(posedge clk);
 end endtask
 initial begin
   repeat(3) @(negedge clk); rst_n=1;
   report(16'h1000,16'h2000);
   if(ons!=1 || last_note!=48) $fatal(1,"initial LIVE note");
   // Y selects the next whole-tone note, but must not retrigger at the same X.
   report(16'h1000,16'h4000); report(16'h1000,16'h4000);
   if(ons!=1) $fatal(1,"Y change retriggered without X movement");
   // One X report is not enough to pass the debounce confirmation.
   report(16'h1e00,16'h4000);
   if(ons!=1) $fatal(1,"single X report bypassed debounce");
   report(16'h1e00,16'h4000);
   if(ons!=2 || last_note!=50) $fatal(1,"X movement did not trigger whole-tone note");
   // The next Y region advances by another whole tone.
   report(16'h1e00,16'h5000); report(16'h1e00,16'h5000);
   if(ons!=2) $fatal(1,"second Y change retriggered without X movement");
   report(16'h1000,16'h5000); report(16'h1000,16'h5000);
   if(ons!=3 || last_note!=52) $fatal(1,"second whole-tone LIVE note failed");
   // Cropped Y regions are ignored and release the current LIVE note.
   report(16'h3000,16'h1000); report(16'h3000,16'h1000);
   if(ons!=3) $fatal(1,"cropped Y unexpectedly selected a note");
   $display("tb_live_note_gate PASS"); $finish;
 end
 initial begin #100000; $fatal(1,"LIVE gate timeout"); end
endmodule
