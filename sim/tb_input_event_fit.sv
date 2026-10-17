`timescale 1ns/1ps
module tb_input_event_fit;
 import control_protocol_pkg::*;
 import performance_event_pkg::*;
 reg clk=0; always #5 clk=~clk;

 // Hysteresis and calibrated full-range mapping under test.
 reg rst_n=0, report_valid=0, xyz_valid=1, report_error=0;
 reg [15:0] x_position=16'h1000, y_position=0, z_position=0;
 reg touch_valid=0; reg [31:0] touch_info=0;
 reg presence_valid=0, present=1;
 reg [3:0] mode=MODE_LIVE; reg [1:0] selected_track=0;
 reg [6:0] loop_tick=0; reg [15:0] start_enter=16'h2000,start_exit=16'h3000;
 reg flush=0, live_ready=1, record_ready=1, modulation_ready=1, record_start_ready=1;
 wire live_valid,record_valid,modulation_valid,record_start,idle,overflow;
 wire [63:0] live_event,record_event,modulation_event;
 input_event_adapter #(.NOTE_CONFIRM(1),.CELL_CONFIRM(1),.COORD_FILTER_SHIFT(0),
   .NOTE_HYSTERESIS(16'd512),.LIVE_Y_MIN(16'h1000),.LIVE_Y_MAX(16'hf000),
   .LIVE_Z_PRESS_CONFIRM(1),.LIVE_Z_RELEASE_CONFIRM(1),
   .LIVE_Z_PRESS_THRESHOLD(16'hffff),.LIVE_Z_RELEASE_THRESHOLD(16'hffff),
   .TIMEOUT_CYCLES(1000)) dut(.*);

 // Filter-only instance: no note hysteresis, so a delayed transition proves
 // the coordinate filter rather than the note-zone dead band.
 reg f_report_valid=0; reg [15:0] f_y_position=16'h1000;
 wire f_live_valid; wire [63:0] f_live_event;
 wire f_record_valid,f_modulation_valid,f_record_start,f_idle,f_overflow;
 wire [63:0] f_record_event,f_modulation_event;
 input_event_adapter #(.NOTE_CONFIRM(1),.CELL_CONFIRM(1),.COORD_FILTER_SHIFT(2),
   .Y_MIN(16'h0000),.Y_MAX(16'hffff),.NOTE_HYSTERESIS(16'd0),
   .LIVE_Z_PRESS_CONFIRM(1),.LIVE_Z_RELEASE_CONFIRM(1),
   .LIVE_Z_PRESS_THRESHOLD(16'hb000),.LIVE_Z_RELEASE_THRESHOLD(16'hf000),
   .TIMEOUT_CYCLES(1000)) filter_dut (
   .clk(clk),.rst_n(rst_n),.report_valid(f_report_valid),.xyz_valid(1'b1),.report_error(1'b0),
   .x_position(16'h1000),.y_position(f_y_position),.z_position(16'h8000),
   .touch_valid(1'b0),.touch_info(32'd0),.presence_valid(1'b0),.present(1'b1),
   .mode(MODE_RECORDING),.selected_track(2'd0),.loop_tick(7'd0),.start_enter(16'h2000),.start_exit(16'h3000),
   .flush(flush),.live_valid(f_live_valid),.live_ready(1'b1),.live_event(f_live_event),
   .record_valid(f_record_valid),.record_ready(1'b1),.record_event(f_record_event),
   .modulation_valid(f_modulation_valid),.modulation_ready(1'b1),.modulation_event(f_modulation_event),
   .record_start(f_record_start),.record_start_ready(1'b1),.idle(f_idle),.overflow(f_overflow));

 integer note_count=0, filter_note_count=0;
 reg [7:0] first_velocity=0, second_velocity=0;
 reg [6:0] first_note=0, second_note=0;
 always @(posedge clk) begin
   if (live_valid && live_ready && live_event[2:0]==EVENT_NOTE_ON) begin
     note_count=note_count+1;
     if (note_count==1) begin first_note=live_event[25:19]; first_velocity=live_event[33:26]; end
     if (note_count==2) begin second_note=live_event[25:19]; second_velocity=live_event[33:26]; end
   end
   if (f_live_valid && f_live_event[2:0]==EVENT_NOTE_ON) filter_note_count=filter_note_count+1;
 end
 task report(input [15:0] y,input [15:0] z); begin
   @(negedge clk); y_position=y; z_position=z; report_valid=1;
   @(posedge clk); #1; @(negedge clk); report_valid=0; repeat(2) @(posedge clk);
 end endtask
 task filter_report(input [15:0] y); begin
   @(negedge clk); f_y_position=y; f_report_valid=1;
   @(posedge clk); #1; @(negedge clk); f_report_valid=0; repeat(1) @(posedge clk);
 end endtask
 task clear; begin @(negedge clk); flush=1; repeat(1) @(posedge clk); #1; @(negedge clk); flush=0; repeat(2) @(posedge clk); end endtask

 initial begin
   repeat(3) @(negedge clk); rst_n=1;
   // The calibrated active sensing surface is 0x1000..0xf000.  0x2800 is
   // still inside C; the first C/D boundary is 0x2c00.
   report(16'h1000,16'h1000); if(note_count!=1 || first_note!=48)$fatal(1,"zone 0 mapping");
   clear(); note_count=0; report(16'h2800,16'h1000); if(note_count!=1 || first_note!=48)$fatal(1,"calibrated zone 0 width");
   clear(); note_count=0; report(16'h3100,16'h1000); if(note_count<1)$fatal(1,"zone 1 is not spatially uniform");
   // Z is inverted: lower sensor Z produces higher velocity.
   clear(); note_count=0; report(16'h1000,16'h1000); if(first_velocity<180)$fatal(1,"low Z should be loud, velocity=%0d",first_velocity);
   clear(); note_count=0; report(16'h1000,16'hf000); if(first_velocity>90)$fatal(1,"high Z should be quiet, velocity=%0d",first_velocity);
   // Hysteresis prevents a line hovering around 0x2000 from retriggering.
   clear(); note_count=0; report(16'h1f00,16'h8000); report(16'h3100,16'h8000);
   if(note_count!=1)$fatal(1,"boundary jitter caused note jump");
   report(16'h3800,16'h8000); if(note_count!=1)$fatal(1,"hysteresis did not accept stable crossing");
   // With hysteresis disabled, the filter must delay a large coordinate jump.
   clear(); filter_note_count=0; filter_report(16'h1000); if(filter_note_count!=1)$fatal(1,"filter baseline note");
   filter_report(16'h7000); if(filter_note_count!=1)$fatal(1,"filter did not suppress one-sample jump");
   repeat(12) filter_report(16'h7000); if(filter_note_count<2)$fatal(1,"filtered coordinate never reached new zone");
   $display("tb_input_event_fit PASS"); $finish;
 end
 initial begin #100000; $fatal(1,"fit test timeout"); end
endmodule
