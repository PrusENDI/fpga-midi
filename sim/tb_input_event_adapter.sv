`timescale 1ns/1ps
module tb_input_event_adapter;
 import control_protocol_pkg::*;
 import performance_event_pkg::*;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,report_valid=0,xyz_valid=1,report_error=0;
 reg [15:0] x_position=16'h1000,y_position=16'h1000,z_position=16'h8000;
 reg touch_valid=1; reg [31:0] touch_info=0;
 reg presence_valid=0,present=0;
 reg [3:0] mode=MODE_IDLE; reg [1:0] selected_track=2;
 reg [6:0] loop_tick=0; reg [15:0] start_enter=16'h2000,start_exit=16'h3000;
 reg flush=0,live_ready=1,record_ready=1,modulation_ready=1,record_start_ready=0;
 wire live_valid,record_valid,modulation_valid,record_start,idle,overflow;
 wire [63:0] live_event,record_event,modulation_event;
 input_event_adapter #(.NOTE_CONFIRM(2),.CELL_CONFIRM(2),.COORD_FILTER_SHIFT(0),.LIVE_X_TRIGGER_DISTANCE(16'h0e00),.LIVE_X_TRIGGER_CONFIRM(1),.LIVE_Y_MIN(16'h1000),.LIVE_Y_MAX(16'hf000),.LIVE_Z_PRESS_CONFIRM(1),.LIVE_Z_RELEASE_CONFIRM(1),.LIVE_Z_PRESS_THRESHOLD(16'hb000),.LIVE_Z_RELEASE_THRESHOLD(16'hf000),.TIMEOUT_CYCLES(100)) dut(.*);
 integer ons=0,offs=0,controls=0,records=0,mods=0;
 reg [63:0] last_record,last_mod,last_on;
 always @(posedge clk) begin
   if(live_valid && live_ready) case(live_event[2:0])
     EVENT_NOTE_ON: begin ons=ons+1; last_on=live_event; end
     EVENT_NOTE_OFF,EVENT_ALL_NOTES_OFF: offs=offs+1;
     EVENT_CONTROL_POINT: controls=controls+1;
   endcase
   if(record_valid && record_ready) begin records=records+1; last_record=record_event; end
   if(modulation_valid && modulation_ready) begin mods=mods+1; last_mod=modulation_event; end
 end
 task step(input integer n); repeat(n) begin @(posedge clk); #1; end endtask
 task report(input [15:0] x,input [15:0] y,input [15:0] z);
   begin @(negedge clk); x_position=x; y_position=y; z_position=z; report_valid=1;
     step(1); @(negedge clk); report_valid=0; step(3); end
 endtask
 task clear_adapter;
   begin @(negedge clk); flush=1; step(1); @(negedge clk); flush=0; step(2); end
 endtask
 integer old_on,old_record;
 reg [63:0] held;
 initial begin
   step(2); rst_n=1; mode=MODE_LIVE;
   report('h1000,'h1000,'h8000); if(ons!=0) $fatal(1,"Y confirmation absent");
   report('h1000,'h1000,'h8000); if(ons!=1 || last_on[25:19]!=48) $fatal(1,"airborne stable C");
   report('h1000,'h1000,'h9000); if(ons!=1 || controls==0) $fatal(1,"Z must only express");
   report('h5000,'h1000,'h9000); report('h5000,'h1000,'h9000);
   if(ons!=2) $fatal(1,"forward retrigger");
   report('h3000,'h1000,'h9000); report('h3000,'h1000,'h9000);
   report('h5000,'h1000,'h9000); report('h5000,'h1000,'h9000);
   if(ons!=2) $fatal(1,"reverse must not reset high water");
   report('h1000,'h1000,'h9000); report('h1000,'h1000,'h9000);
   report('h5000,'h1000,'h9000); report('h5000,'h1000,'h9000);
   if(ons!=3) $fatal(1,"left rearm");
   presence_valid=1; present=0; report('h5000,'h1000,'h9000);
   if(offs<3) $fatal(1,"presence release"); presence_valid=0;
   clear_adapter(); mode=MODE_RECORD_ARMED;
   report('h1000,'h1000,'h8000); report('h5000,'h1000,'h8000);
   if(record_start) $fatal(1,"majority fired early");
   report('h1000,'h1000,'h8000); step(4); if(!record_start) $fatal(1,"majority held request");
   record_start_ready=1; step(1); record_start_ready=0;
   report('h1000,'h1000,'h8000); if(record_start) $fatal(1,"start must rearm");
   mode=MODE_RECORDING; loop_tick=5;
   report('h1000,'h1000,'h3000); report('h1000,'h1000,'h3000);
   loop_tick=9; selected_track=1; record_ready=0;
   report('h1000,'hf000,'h8000); report('h1000,'hf000,'h8000);
   if(!record_valid || record_event[11:5]!=5 || record_event[18:12]!=4 || record_event[4:3]!=2)
     $fatal(1,"completed duration original tick/track");
   held=record_event; step(4); if(!record_valid || record_event!==held) $fatal(1,"record hold");
   record_ready=1; step(2);
   loop_tick=0; mode=MODE_COMMIT_PENDING; step(3);
   if(last_record[11:5]!=9 || last_record[18:12]!=119 || last_record[25:19]!=60 || !idle)
     $fatal(1,"boundary tail drain");
   clear_adapter(); mode=MODE_RECORDING; loop_tick=0; selected_track=0;
   report('h1000,'h1000,'h8000); report('h1000,'h1000,'h8000);
   old_record=records;
   report('h5000,'h1000,'h8000); report('h5000,'h1000,'h8000);
   if(records!=old_record) $fatal(1,"same tick same note must merge");
   mode=MODE_COMMIT_PENDING; step(3);
   if(last_record[11:5]!=0 || last_record[18:12]!=0) $fatal(1,"128 tick duration encoding");
   clear_adapter(); mode=MODE_PLAY; old_on=ons;
   report('h8000,'h8000,'h8000);
   if(mods==0 || last_mod[41:34]!=0 || last_mod[49:42]!=128 || last_mod[57:50]!=128 || ons!=old_on)
     $fatal(1,"play neutral modulation");
   report('hf000,'hf000,'hf000);
   step(105);
   if(modulation_valid)
     $fatal(1,"PLAY timeout must clear modulation");
   report('hf000,'hf000,'hf000); mode=MODE_IDLE; step(3);
   if(modulation_valid)
     $fatal(1,"PLAY exit must clear modulation");
   mode=MODE_PLAY;
   modulation_ready=0; report('hf000,'hf000,'hf000); held=modulation_event;
   step(3); if(!modulation_valid || modulation_event!==held) $fatal(1,"modulation hold");
   clear_adapter(); if(modulation_valid || overflow) $fatal(1,"flush cancels modulation");
   modulation_ready=1; mode=MODE_LIVE;
   // One-cycle downstream stalls are normal. A single pending event plus one
   // additional event fits the adapter's two-entry live queue and must not
   // be reported as overflow.
   report('h1000,'h1000,'h8000); report('h1000,'h1000,'h8000);
   live_ready=0;
   report('h1000,'h1000,'h9000); report('h1000,'h1000,'ha000);
   if(overflow) $fatal(1,"two-entry live queue falsely overflowed");
   live_ready=1; step(4); clear_adapter(); mode=MODE_LIVE;
   report('h1000,'h1000,'h8000); report('h1000,'h1000,'h8000);
   live_ready=0; report('h8000,'hf000,'h3000); report('h8000,'hf000,'h3000);
   held=live_event; step(3); if(!live_valid || live_event!==held) $fatal(1,"live hold");
   report('h5000,'hf000,'h3000);
   if(overflow || !live_valid) $fatal(1,"LIVE stall must coalesce without overflow");
   live_ready=1; step(3);
   old_on=ons;
   report('h1000,'h1000,'h8000); report('h1000,'h1000,'h8000);
   report('h1000,'h1000,'h3000); report('h1000,'h1000,'h3000);
   report('h8000,'h1000,'h3000); report('h8000,'h1000,'h3000);
   if(ons<=old_on) $fatal(1,"LIVE must recover after safeoff handshake");
   clear_adapter();
   report('h1000,'h1000,'h8000); report('h1000,'h1000,'h8000);
   old_on=offs; step(105); if(offs<=old_on) $fatal(1,"timeout release");
   $display("tb_input_event_adapter PASS"); $finish;
 end
 initial begin #100000; $fatal(1,"test timeout"); end
endmodule
