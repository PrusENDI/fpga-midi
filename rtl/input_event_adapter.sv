// Approved Loop gesture interface; deliberately separate from the legacy
// pattern input (which ends at the right edge and has a different note map).
// Raw touch is diagnostic-only: zero contact electrodes is NOT absent hand.
// Presence release uses only the explicitly decoded presence_valid/present.
//
// live_event: immediate OFF/ON/control, never write these into Loop RAM.
// record_event: completed NOTE_ON with original tick/track and duration. A
// full 128-tick note starting at zero uses duration=0 (boundary ALL_NOTES_OFF).
// Same-tick same-note X retriggers remain audible but merge in the record.
// Modulation: CONTROL_POINT, signed pitch -64..63 (X[15:9]-64), unsigned
// offset amp=Z[15:8], timbre=Y[15:8], neutral=128, pitch neutral=0.
// Live expression: velocity=64+Z[15:9], amplitude/timbre=Z[15:8].
//
// Storage is bounded: two live events, one completed record, one modulation.
// A new report while an output is blocked trips sticky overflow and publishes
// ALL_NOTES_OFF. Overflow and flush explicitly CANCEL pending output contracts.
// Consumer must abort the take on overflow. No lossless claim is made for
// unbackpressurable sensor reports. idle includes all queued tails; manager
// must include it in its commit drain predicate. flush clears sticky overflow.
module input_event_adapter #(
 parameter integer NOTE_CONFIRM=6,
 parameter integer CELL_CONFIRM=2,
 parameter integer X_HYSTERESIS=256,
 parameter integer TIMEOUT_CYCLES=5000000
)(
 input wire clk,rst_n,report_valid,xyz_valid,report_error,
 input wire [15:0] x_position,y_position,z_position,
 input wire touch_valid,input wire [31:0] touch_info,
 input wire presence_valid,present,
 input wire [3:0] mode,input wire [1:0] selected_track,
 input wire [6:0] loop_tick,input wire [15:0] start_enter,start_exit,
 input wire flush,
 output wire live_valid,input wire live_ready,output wire [63:0] live_event,
 output reg record_valid,input wire record_ready,output reg [63:0] record_event,
 output reg modulation_valid,input wire modulation_ready,output reg [63:0] modulation_event,
 output reg record_start,input wire record_start_ready,
 output wire idle,output reg overflow
);
 import control_protocol_pkg::*;
 import performance_event_pkg::*;
 reg [1:0] live_count;
 reg [63:0] live_head,live_tail;
 reg [3:0] prior_mode;
 reg note_active,record_active,start_armed;
 reg [6:0] active_note,note_candidate;
 reg [1:0] active_track;
 reg [15:0] note_count,cell_count;
 reg [2:0] cell_position,cell_candidate,cell_highwater;
 reg [2:0] start_history;
 reg [7:0] last_expression;
 reg [63:0] record_note;
 reg [31:0] timeout_count;
 wire capturing=mode==MODE_RECORDING || mode==MODE_OVERDUB;
 wire performing=mode==MODE_LIVE || capturing;
 wire prior_capture=prior_mode==MODE_RECORDING || prior_mode==MODE_OVERDUB;
 wire good_report=report_valid && xyz_valid && !report_error && !(presence_valid && !present);
 wire release_report=report_valid && (!xyz_valid || report_error || (presence_valid && !present));
 wire expired=timeout_count>=TIMEOUT_CYCLES-1;
 wire outputs_blocked=(live_count!=0 && !live_ready) || (record_valid && !record_ready) ||
                      (modulation_valid && !modulation_ready);
 assign live_valid=live_count!=0;
 assign live_event=live_head;
 assign idle=live_count==0 && !record_valid && !modulation_valid && !record_active;

 function automatic [2:0] zone(input [15:0] value);
   integer scaled;
   begin
     if(value<=16'h1000) zone=0;
     else if(value>=16'hf000) zone=7;
     else begin scaled=(value-4096)/7168; zone=scaled[2:0]; end
   end
 endfunction
 function automatic [6:0] mapped_note(input [15:0] value);
   begin case(zone(value))
     0:mapped_note=48; 1:mapped_note=50; 2:mapped_note=52; 3:mapped_note=53;
     4:mapped_note=55; 5:mapped_note=57; 6:mapped_note=59; 7:mapped_note=60;
   endcase end
 endfunction
 function automatic [63:0] event_word(input [2:0] kind,input [6:0] note_value,input [1:0] track);
   reg [63:0] value;
   begin
     value=0; value[2:0]=kind; value[4:3]=track; value[11:5]=loop_tick;
     value[25:19]=note_value; value[33:26]=8'd64+{1'b0,z_position[15:9]};
     value[49:42]=z_position[15:8]; value[57:50]=z_position[15:8];
     event_word=value;
   end
 endfunction
 wire [6:0] next_note=mapped_note(y_position);
 wire note_confirmed=(next_note==note_candidate && note_count>=NOTE_CONFIRM-1) || NOTE_CONFIRM<=1;
 wire [2:0] raw_cell=zone(x_position);
 // Cell changes require crossing the shared boundary plus a dead band.
 wire above_cell=x_position >= (4096+(cell_position+1)*7168+X_HYSTERESIS);
 wire below_cell=x_position+X_HYSTERESIS < (4096+cell_position*7168);
 wire [2:0] next_cell=((raw_cell>cell_position && above_cell) ||
                       (raw_cell<cell_position && below_cell))?raw_cell:cell_position;
 wire cell_confirmed=(next_cell==cell_candidate && cell_count>=CELL_CONFIRM-1) || CELL_CONFIRM<=1;
 wire forward_cross=cell_confirmed && next_cell>cell_highwater;
 wire [2:0] next_history={start_history[1:0],x_position<=start_enter};
 wire majority=(next_history[0] && next_history[1]) || (next_history[0] && next_history[2]) ||
               (next_history[1] && next_history[2]);
 task safe_overflow;
 begin
   overflow<=1; live_count<=1; live_head<=event_word(EVENT_ALL_NOTES_OFF,0,selected_track);
   record_valid<=0; modulation_valid<=0; note_active<=0; record_active<=0; record_start<=0;
 end
 endtask
 task live_one(input [63:0] value);
 begin
   if(live_count==0 || (live_count==1 && live_ready)) begin live_head<=value; live_count<=1; end
   else if(live_count==1 || live_ready) begin live_tail<=value; live_count<=2; end
   else safe_overflow();
 end
 endtask
 task live_pair(input [63:0] first,input [63:0] second);
 begin
   if(live_count==0 || (live_count==1 && live_ready)) begin
     live_head<=first; live_tail<=second; live_count<=2;
   end else safe_overflow();
 end
 endtask
 task close_record(input boundary_end);
   integer duration;
   reg [63:0] completed;
   begin
     if(record_active) begin
       if(record_valid && !record_ready) safe_overflow();
       else begin
         if(boundary_end) duration=128-record_note[11:5];
         else begin duration=(loop_tick-record_note[11:5]) & 127; if(duration==0) duration=1; end
         completed=record_note; completed[18:12]=(duration==128)?7'd0:duration[6:0];
         record_event<=completed; record_valid<=1; record_active<=0;
       end
     end
   end
 endtask
 task release_note(input boundary_end);
 begin
   if(note_active) live_one(event_word(EVENT_NOTE_OFF,active_note,active_track));
   close_record(boundary_end); note_active<=0; note_count<=0; cell_count<=0;
 end
 endtask
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     live_count<=0; live_head<=0; live_tail<=0; record_valid<=0; record_event<=0;
     modulation_valid<=0; modulation_event<=0; record_start<=0; overflow<=0;
     prior_mode<=MODE_IDLE; note_active<=0; record_active<=0; start_armed<=1;
     active_note<=0; active_track<=0; note_candidate<=0; note_count<=0; cell_count<=0;
     cell_position<=0; cell_candidate<=0; cell_highwater<=0; start_history<=0;
     last_expression<=0; record_note<=0; timeout_count<=0;
   end else begin
     prior_mode<=mode;
     if(live_count!=0 && live_ready) begin live_head<=live_tail; live_count<=live_count-1'b1; end
     if(record_valid && record_ready) record_valid<=0;
     if(modulation_valid && modulation_ready) modulation_valid<=0;
     if(record_start && record_start_ready) record_start<=0;
     if(good_report) timeout_count<=0;
     else if(!expired) timeout_count<=timeout_count+1'b1;
     if(flush) begin
       live_count<=0; record_valid<=0; modulation_valid<=0; record_start<=0; overflow<=0;
       note_active<=0; record_active<=0; note_count<=0; cell_count<=0;
       cell_highwater<=0; cell_position<=0; cell_candidate<=0; start_history<=0;
       start_armed<=1; timeout_count<=0;
     end else if(!overflow) begin
       // Boundary completion takes priority over even a same-edge sensor report.
       if(prior_capture && !capturing) begin
         release_note(mode==MODE_COMMIT_PENDING);
       end else if((note_active && !performing) || release_report || (expired && note_active)) begin
         release_note(0);
         if(mode==MODE_PLAY) begin
           modulation_valid<=1; modulation_event<=64'h0;
           modulation_event[2:0]<=EVENT_CONTROL_POINT;
           modulation_event[49:42]<=128; modulation_event[57:50]<=128;
         end
       end else if(expired || (prior_mode==MODE_PLAY && mode!=MODE_PLAY && mode!=MODE_OVERDUB_ARMED)) begin
         modulation_valid<=0;
       end else if(good_report) begin
         if(outputs_blocked) safe_overflow();
         else begin
           if(mode==MODE_RECORD_ARMED) begin
             start_history<=next_history;
             if(!start_armed && x_position>=start_exit) begin start_armed<=1; start_history<=0; end
             if(start_armed && majority) begin record_start<=1; start_armed<=0; start_history<=0; end
           end
           if(performing) begin
             if(next_note==note_candidate) begin if(note_count<NOTE_CONFIRM) note_count<=note_count+1'b1; end
             else begin note_candidate<=next_note; note_count<=1; end
             if(next_cell==cell_candidate) begin if(cell_count<CELL_CONFIRM) cell_count<=cell_count+1'b1; end
             else begin cell_candidate<=next_cell; cell_count<=1; end
             if(cell_confirmed) begin
               cell_position<=next_cell;
               if(x_position<=start_enter) cell_highwater<=next_cell;
               else if(next_cell>cell_highwater) cell_highwater<=next_cell;
             end
             if(note_confirmed && (!note_active || next_note!=active_note)) begin
               if(note_active) live_pair(event_word(EVENT_NOTE_OFF,active_note,active_track),event_word(EVENT_NOTE_ON,next_note,selected_track));
               else live_one(event_word(EVENT_NOTE_ON,next_note,selected_track));
               close_record(0);
               active_note<=next_note; active_track<=selected_track; note_active<=1;
               if(capturing) begin record_note<=event_word(EVENT_NOTE_ON,next_note,selected_track); record_active<=1; end
               last_expression<=z_position[15:8];
             end else if(note_active && forward_cross) begin
               live_pair(event_word(EVENT_NOTE_OFF,active_note,active_track),event_word(EVENT_NOTE_ON,active_note,active_track));
               if(capturing && (!record_active || record_note[11:5]!=loop_tick)) begin
                 close_record(0); record_note<=event_word(EVENT_NOTE_ON,active_note,active_track); record_active<=1;
               end
               last_expression<=z_position[15:8];
             end else if(note_active && last_expression!=z_position[15:8]) begin
               live_one(event_word(EVENT_CONTROL_POINT,active_note,active_track));
               last_expression<=z_position[15:8];
               if(record_active) begin
                 record_note[33:26]<=8'd64+{1'b0,z_position[15:9]};
                 record_note[49:42]<=z_position[15:8]; record_note[57:50]<=z_position[15:8];
               end
             end
           end else if(mode==MODE_PLAY || mode==MODE_OVERDUB_ARMED) begin
             modulation_valid<=1; modulation_event<=event_word(EVENT_CONTROL_POINT,0,selected_track);
             modulation_event[41:34]<={1'b0,x_position[15:9]}-8'd64;
             modulation_event[49:42]<=z_position[15:8]; modulation_event[57:50]<=y_position[15:8];
           end
         end
       end
       if(mode!=MODE_RECORD_ARMED) begin record_start<=0; start_history<=0; end
       // Leaving PLAY removes the external modulation layer. This explicit
       // mode cancellation may withdraw a stalled modulation event.
       if(prior_mode==MODE_PLAY && mode!=MODE_PLAY && mode!=MODE_OVERDUB_ARMED) modulation_valid<=0;
     end
   end
 end
endmodule
