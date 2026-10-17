`timescale 1ns/1ps
module tb_live_input_quality;
 import control_protocol_pkg::*;
 import performance_event_pkg::*;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0, report_valid=0, xyz_valid=1, report_error=0;
 reg [15:0] x_position=16'h6000, y_position=16'h4000, z_position=16'hc000;
 reg touch_valid=0; reg [31:0] touch_info=0;
 reg presence_valid=0, present=1;
 reg [3:0] mode=MODE_LIVE; reg [1:0] selected_track=0;
 reg [6:0] loop_tick=0; reg [15:0] start_enter=16'h2000,start_exit=16'h3000;
 reg flush=0, live_ready=1, record_ready=1, modulation_ready=1, record_start_ready=1;
 wire live_valid,record_valid,modulation_valid,record_start,idle,overflow;
 wire [63:0] live_event,record_event,modulation_event;
 input_event_adapter #(
   .NOTE_CONFIRM(1), .CELL_CONFIRM(1), .COORD_FILTER_SHIFT(0),
   .LIVE_X_TRIGGER_CONFIRM(1), .LIVE_X_TRIGGER_DISTANCE(16'h0e00),
   .LIVE_Z_PRESS_CONFIRM(2), .LIVE_Z_RELEASE_CONFIRM(2),
   .LIVE_Z_FILTER_SHIFT(0),
   .XY_DECOUPLE_DEADBAND(16'h0100), .TIMEOUT_CYCLES(1000)) dut(.*);
 integer ons=0, offs=0;
 reg [6:0] last_on_note=0;
 always @(posedge clk) if(live_valid && live_ready) begin
   if(live_event[2:0]==EVENT_NOTE_ON) begin ons=ons+1; last_on_note=live_event[25:19]; end
   if(live_event[2:0]==EVENT_NOTE_OFF) offs=offs+1;
 end
 task report(input [15:0] x,input [15:0] y,input [15:0] z); begin
   @(negedge clk); x_position=x; y_position=y; z_position=z; report_valid=1;
   @(posedge clk); #1; @(negedge clk); report_valid=0; repeat(2) @(posedge clk);
 end endtask
 initial begin
   repeat(3) @(negedge clk); rst_n=1;
   // Z is below the press threshold: vertical selection alone is silent.
   report(16'h6000,16'h4000,16'hc000); report(16'h6000,16'h4000,16'hc000);
   if(ons!=0) $fatal(1,"unpressed Z started a note");
   // Two confirmed press reports start the selected note.
   report(16'h6000,16'h4000,16'h3000); report(16'h6000,16'h4000,16'h3000);
   if(ons!=1 || last_on_note!=50) $fatal(1,"Z press did not start note");
   // Y motion carries a large X error; dominant-axis separation must ignore it.
   report(16'h7000,16'h6000,16'h3000); report(16'h7000,16'h6000,16'h3000);
   if(ons!=1) $fatal(1,"Y motion leaked into X trigger");
   // Genuine X motion while Y is stable selects the pending whole-tone note.
   report(16'h8000,16'h6000,16'h3000); report(16'h8000,16'h6000,16'h3000); report(16'h8000,16'h6000,16'h3000);
   if(ons!=2 || last_on_note!=54) $fatal(1,"X motion did not trigger pending Y note");
   // Release and press Z again: the same note must retrigger cleanly.
   report(16'h8000,16'h6000,16'hc000); report(16'h8000,16'h6000,16'hc000);
   if(offs==0) $fatal(1,"Z release did not stop note");
   report(16'h8000,16'h6000,16'h3000); report(16'h8000,16'h6000,16'h3000);
   if(ons!=3 || last_on_note!=54) $fatal(1,"same note did not retrigger");
   $display("tb_live_input_quality PASS"); $finish;
 end
 initial begin #100000; $fatal(1,"LIVE quality timeout"); end
endmodule
