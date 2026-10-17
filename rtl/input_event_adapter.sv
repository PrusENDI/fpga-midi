// Approved Loop gesture interface; deliberately separate from the legacy
// pattern input (which ends at the right edge and has a different note map).
// Raw touch is diagnostic-only: zero contact electrodes is NOT absent hand.
// Presence release uses only the explicitly decoded presence_valid/present.
//
// live_event: immediate OFF/ON/control, never write these into Loop RAM.
// record_event: completed NOTE_ON with original tick/track and duration. A
// full 128-tick note starting at zero uses duration=0 (boundary ALL_NOTES_OFF).
// Same-tick same-note X retriggers remain audible but merge in the record.
// Modulation: CONTROL_POINT, signed pitch -64..63 (filtered X[15:9]-64),
// inverted Z level for amp/timbre, neutral=128, pitch neutral=0.
// Coordinates use a one-pole integer low-pass; Y zone transitions include a
// calibrated dead band so a hand hovering on a boundary does not retrigger.
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
 parameter integer COORD_FILTER_SHIFT=2,
 parameter [15:0] X_MIN=16'h1000,
 parameter [15:0] X_MAX=16'hf000,
 parameter [15:0] Y_MIN=16'h1000,
 parameter [15:0] Y_MAX=16'hf000,
 parameter [15:0] LIVE_Y_MIN=16'h1700,
 parameter [15:0] LIVE_Y_MAX=16'he900,
 // LIVE-only calibrated Y boundaries. The lower half is slightly expanded
 // because the MGC3130 coordinate field is typically denser there. Override
 // these from the board top after collecting raw Y reports if needed.
 parameter [15:0] LIVE_Y_B1=16'h2b40,
 parameter [15:0] LIVE_Y_B2=16'h4580,
 parameter [15:0] LIVE_Y_B3=16'h5fc0,
 parameter [15:0] LIVE_Y_B4=16'h7a00,
 parameter [15:0] LIVE_Y_B5=16'h9440,
 parameter [15:0] LIVE_Y_B6=16'hae80,
 parameter [15:0] LIVE_Y_B7=16'hc8c0,
 parameter integer NOTE_HYSTERESIS=512,
 parameter integer LIVE_X_TRIGGER_CONFIRM=2,
 parameter integer LIVE_X_TRIGGER_DISTANCE=3584,
 parameter integer LIVE_Z_PRESS_CONFIRM=2,
 parameter integer LIVE_Z_RELEASE_CONFIRM=2,
 parameter integer LIVE_Z_FILTER_SHIFT=1,
 parameter [15:0] LIVE_Z_PRESS_THRESHOLD=16'h9000,
 parameter [15:0] LIVE_Z_RELEASE_THRESHOLD=16'hb000,
 parameter [15:0] XY_DECOUPLE_DEADBAND=16'h0100,
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
 reg overflow_blocked;
 reg coord_initialized;
 reg [15:0] x_filtered,y_filtered,z_filtered;
 reg [2:0] note_zone_active;
 reg [15:0] live_x_anchor;
 reg [15:0] live_x_trigger_count;
 reg live_rearmed;
 reg live_z_pressed;
 reg [15:0] live_z_press_count,live_z_release_count;
 reg [15:0] raw_x_previous,raw_y_previous;
 reg [15:0] live_x_decoupled,live_y_decoupled;
 reg [1:0] motion_axis;
 wire capturing=mode==MODE_RECORDING || mode==MODE_OVERDUB;
 wire performing=mode==MODE_LIVE || capturing;
 wire prior_capture=prior_mode==MODE_RECORDING || prior_mode==MODE_OVERDUB;
 wire good_report=report_valid && xyz_valid && !report_error && !(presence_valid && !present);
 wire release_report=report_valid && (!xyz_valid || report_error || (presence_valid && !present));
 wire expired=timeout_count>=TIMEOUT_CYCLES-1;
 wire outputs_blocked=(live_count==2 && !live_ready) || (record_valid && !record_ready) ||
                      (modulation_valid && !modulation_ready);
 assign live_valid=live_count!=0;
 assign live_event=live_head;
 assign idle=live_count==0 && !record_valid && !modulation_valid && !record_active;

 function automatic [15:0] smooth_coord(input [15:0] current,input [15:0] target);
   integer diff;
   begin
     if(COORD_FILTER_SHIFT==0) smooth_coord=target;
     else if(target>=current) begin
       diff=target-current; smooth_coord=current+(diff>>COORD_FILTER_SHIFT);
     end else begin
       diff=current-target; smooth_coord=current-(diff>>COORD_FILTER_SHIFT);
     end
   end
 endfunction
 function automatic [2:0] zone(input [15:0] value);
   integer scaled;
   begin
     if(value<=Y_MIN) zone=0;
     else if(value>=Y_MAX) zone=7;
     else begin
       scaled=((value-Y_MIN)*8)/(Y_MAX-Y_MIN);
       if(scaled>7) scaled=7;
       zone=scaled[2:0];
     end
   end
 endfunction
 function automatic [2:0] cell_zone(input [15:0] value);
   integer scaled;
   begin
     if(value<=X_MIN) cell_zone=0;
     else if(value>=X_MAX) cell_zone=7;
     else begin
       scaled=((value-X_MIN)*8)/(X_MAX-X_MIN);
       if(scaled>7) scaled=7;
       cell_zone=scaled[2:0];
     end
   end
 endfunction
 function automatic [2:0] hysteretic_zone(input [15:0] value,input [2:0] current);
   integer ivalue,lower,upper,span,target;
   begin
     span=Y_MAX-Y_MIN; ivalue=value;
     target=zone(value);
     lower=Y_MIN+(current*span)/8;
     upper=Y_MIN+((current+1)*span)/8;
     hysteretic_zone=current;
     if(target>current && ivalue>(upper+NOTE_HYSTERESIS))
       hysteretic_zone=target[2:0];
     else if(target<current && ivalue+NOTE_HYSTERESIS<lower)
       hysteretic_zone=target[2:0];
   end
 endfunction
 function automatic [2:0] live_zone(input [15:0] value);
   begin
     if(value<LIVE_Y_B1) live_zone=0;
     else if(value<LIVE_Y_B2) live_zone=1;
     else if(value<LIVE_Y_B3) live_zone=2;
     else if(value<LIVE_Y_B4) live_zone=3;
     else if(value<LIVE_Y_B5) live_zone=4;
     else if(value<LIVE_Y_B6) live_zone=5;
     else if(value<LIVE_Y_B7) live_zone=6;
     else live_zone=7;
   end
 endfunction
 function automatic [2:0] live_hysteretic_zone(input [15:0] value,input [2:0] current);
   integer ivalue,lower,upper;
   begin
     ivalue=value;
     case(current)
       0: begin lower=LIVE_Y_MIN; upper=LIVE_Y_B1; end
       1: begin lower=LIVE_Y_B1; upper=LIVE_Y_B2; end
       2: begin lower=LIVE_Y_B2; upper=LIVE_Y_B3; end
       3: begin lower=LIVE_Y_B3; upper=LIVE_Y_B4; end
       4: begin lower=LIVE_Y_B4; upper=LIVE_Y_B5; end
       5: begin lower=LIVE_Y_B5; upper=LIVE_Y_B6; end
       6: begin lower=LIVE_Y_B6; upper=LIVE_Y_B7; end
       default: begin lower=LIVE_Y_B7; upper=LIVE_Y_MAX; end
     endcase
     live_hysteretic_zone=current;
     if(live_zone(value)>current && ivalue>(upper+NOTE_HYSTERESIS)) live_hysteretic_zone=live_zone(value);
     else if(live_zone(value)<current && ivalue+NOTE_HYSTERESIS<lower) live_hysteretic_zone=live_zone(value);
   end
 endfunction
 function automatic [6:0] note_from_zone(input [2:0] value);
   begin case(value)
     0:note_from_zone=48; 1:note_from_zone=50; 2:note_from_zone=52; 3:note_from_zone=53;
     4:note_from_zone=55; 5:note_from_zone=57; 6:note_from_zone=59; 7:note_from_zone=60;
   endcase end
 endfunction
 function automatic [6:0] live_note_from_zone(input [2:0] value);
   begin live_note_from_zone=7'd48+(value<<1); end
 endfunction
 function automatic [7:0] map_velocity(input [15:0] value);
   integer level;
   begin
     level=256-(value>>8);
     if(level>255) level=255;
     if(level<32) level=32;
     map_velocity=level[7:0];
   end
 endfunction
 function automatic [15:0] add_coord_delta(input [15:0] current,input signed [16:0] delta);
   integer signed value;
   begin
     value=$signed({1'b0,current})+delta;
     if(value<0) add_coord_delta=0;
     else if(value>65535) add_coord_delta=65535;
     else add_coord_delta=value[15:0];
   end
 endfunction
 wire signed [16:0] raw_dx=$signed({1'b0,x_position})-$signed({1'b0,raw_x_previous});
 wire signed [16:0] raw_dy=$signed({1'b0,y_position})-$signed({1'b0,raw_y_previous});
 wire [16:0] x_motion_delta=(raw_dx<0)?-raw_dx:raw_dx;
 wire [16:0] y_motion_delta=(raw_dy<0)?-raw_dy:raw_dy;
 wire y_dominant=(y_motion_delta > (x_motion_delta + XY_DECOUPLE_DEADBAND));
 wire x_dominant=(x_motion_delta > (y_motion_delta + XY_DECOUPLE_DEADBAND));
 // A clear direction switches immediately; diagonal/small motion retains the
 // previous direction. Integrate only that axis, never replay rejected drift.
 wire [1:0] next_axis=y_dominant?2'd2:(x_dominant?2'd1:motion_axis);
 wire [15:0] live_x_next=(next_axis==1)?add_coord_delta(live_x_decoupled,raw_dx):live_x_decoupled;
 wire [15:0] live_y_next=(next_axis==2)?add_coord_delta(live_y_decoupled,raw_dy):live_y_decoupled;
 wire [15:0] target_x=(mode==MODE_LIVE)?live_x_next:x_position;
 wire [15:0] target_y=(mode==MODE_LIVE)?live_y_next:y_position;
 wire [15:0] coord_x=good_report ? (coord_initialized ? smooth_coord(x_filtered,target_x) : x_position) :
                              (coord_initialized ? x_filtered : x_position);
 wire [15:0] coord_y=good_report ? (coord_initialized ? smooth_coord(y_filtered,target_y) : y_position) :
                              (coord_initialized ? y_filtered : y_position);
 function automatic [15:0] smooth_live_z(input [15:0] current,input [15:0] target);
   integer difference;
   begin
     difference=(target>=current)?target-current:current-target;
     if(target>=current) smooth_live_z=current+(difference>>LIVE_Z_FILTER_SHIFT);
     else smooth_live_z=current-(difference>>LIVE_Z_FILTER_SHIFT);
   end
 endfunction
 wire [15:0] coord_z=good_report ? (coord_initialized ?
   ((mode==MODE_LIVE)?smooth_live_z(z_filtered,z_position):smooth_coord(z_filtered,z_position)) : z_position) :
                              (coord_initialized ? z_filtered : z_position);
 wire [7:0] z_level=map_velocity(coord_z);
 function automatic [63:0] event_word(input [2:0] kind,input [6:0] note_value,input [1:0] track);
   reg [63:0] value;
   begin
     value=0; value[2:0]=kind; value[4:3]=track; value[11:5]=loop_tick;
     value[25:19]=note_value; value[33:26]=map_velocity(coord_z);
     value[49:42]=z_level; value[57:50]=z_level;
     value[60]=(kind != EVENT_ALL_NOTES_OFF);
     event_word=value;
   end
 endfunction
 wire live_y_valid=(coord_y>=LIVE_Y_MIN && coord_y<=LIVE_Y_MAX);
 wire [2:0] raw_note_zone=(mode==MODE_LIVE) ? live_zone(coord_y) : zone(coord_y);
 wire [2:0] next_note_zone=note_active ?
   ((mode==MODE_LIVE) ? live_hysteretic_zone(coord_y,note_zone_active) : hysteretic_zone(coord_y,note_zone_active)) : raw_note_zone;
 wire [6:0] next_note=(mode==MODE_LIVE) ? live_note_from_zone(next_note_zone) : note_from_zone(next_note_zone);
 wire note_confirmed=(next_note==note_candidate && note_count>=NOTE_CONFIRM-1) || NOTE_CONFIRM<=1;
 wire [15:0] live_x_delta=(coord_x>=live_x_anchor)?(coord_x-live_x_anchor):(live_x_anchor-coord_x);
 wire live_x_far=(live_x_delta>=LIVE_X_TRIGGER_DISTANCE);
 wire live_z_press_sample=(coord_z<=LIVE_Z_PRESS_THRESHOLD);
 wire live_z_release_sample=(coord_z>=LIVE_Z_RELEASE_THRESHOLD);
 wire live_z_press_confirmed=(live_z_press_count+1>=LIVE_Z_PRESS_CONFIRM);
 wire live_z_release_confirmed=(live_z_release_count+1>=LIVE_Z_RELEASE_CONFIRM);
 wire live_z_releasing=live_z_pressed && live_z_release_sample && live_z_release_confirmed;
 wire live_z_gate=!live_z_releasing && (live_z_pressed || (live_z_press_sample && live_z_press_confirmed));
 wire [2:0] raw_cell=cell_zone(coord_x);
 // Cell changes require crossing the shared boundary plus a dead band.
 wire above_cell=coord_x >= (X_MIN+(cell_position+1)*((X_MAX-X_MIN)/8)+X_HYSTERESIS);
 wire below_cell=coord_x+X_HYSTERESIS < (X_MIN+cell_position*((X_MAX-X_MIN)/8));
 wire [2:0] next_cell=((raw_cell>cell_position && above_cell) ||
                       (raw_cell<cell_position && below_cell))?raw_cell:cell_position;
 wire cell_confirmed=(next_cell==cell_candidate && cell_count>=CELL_CONFIRM-1) || CELL_CONFIRM<=1;
 wire forward_cross=cell_confirmed && next_cell>cell_highwater;
 wire [2:0] next_history={start_history[1:0],coord_x<=start_enter};
 wire majority=(next_history[0] && next_history[1]) || (next_history[0] && next_history[2]) ||
               (next_history[1] && next_history[2]);
 task safe_overflow;
 begin
   overflow<=1; overflow_blocked<=1; live_count<=1; live_head<=event_word(EVENT_ALL_NOTES_OFF,0,selected_track);
   record_valid<=0; modulation_valid<=0; note_active<=0; record_active<=0; record_start<=0;
 end
 endtask
 task live_one(input [63:0] value);
 begin
   if(live_count==0 || (live_count==1 && live_ready)) begin live_head<=value; live_count<=1; end
   else if(live_count==1 || live_ready) begin live_tail<=value; live_count<=2; end
   else if(mode==MODE_LIVE) begin
     // LIVE is a lossy monitor by design: if the mixer is temporarily
     // blocked, retain a safe release followed by the newest event instead
     // of applying recording-style overflow/fault semantics.
     live_head<=event_word(EVENT_ALL_NOTES_OFF,0,selected_track);
     live_tail<=value; live_count<=2;
   end else safe_overflow();
 end
 endtask
 task live_pair(input [63:0] first,input [63:0] second);
 begin
   if(live_count==0 || (live_count==1 && live_ready)) begin
     live_head<=first; live_tail<=second; live_count<=2;
   end else if(mode==MODE_LIVE) begin
     live_head<=event_word(EVENT_ALL_NOTES_OFF,0,selected_track);
     live_tail<=second; live_count<=2;
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
         completed[60]=1'b0;
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
     prior_mode<=MODE_IDLE; note_active<=0; record_active<=0; start_armed<=1; overflow_blocked<=0;
     coord_initialized<=0; x_filtered<=0; y_filtered<=0; z_filtered<=0; note_zone_active<=0;
     live_x_anchor<=0; live_x_trigger_count<=0;
     live_rearmed<=0;
     live_z_pressed<=0; live_z_press_count<=0; live_z_release_count<=0;
     raw_x_previous<=0; raw_y_previous<=0; live_x_decoupled<=0; live_y_decoupled<=0; motion_axis<=0;
     active_note<=0; active_track<=0; note_candidate<=0; note_count<=0; cell_count<=0;
     cell_position<=0; cell_candidate<=0; cell_highwater<=0; start_history<=0;
     last_expression<=0; record_note<=0; timeout_count<=0;
   end else begin
     prior_mode<=mode;
     if(live_count!=0 && live_ready) begin
       live_head<=live_tail; live_count<=live_count-1'b1;
       // The safety ALL_NOTES_OFF event is the only item emitted while an
       // overflow is blocked.  Once it is accepted, LIVE can resume while
       // the public overflow flag remains sticky until an explicit flush.
       if(overflow_blocked && live_count==1 && mode==MODE_LIVE) overflow_blocked<=0;
       if(overflow_blocked && live_count==1 && mode==MODE_LIVE) begin
         note_active<=0;
         live_rearmed<=0;
       end
     end
     if(record_valid && record_ready) record_valid<=0;
     if(modulation_valid && modulation_ready) modulation_valid<=0;
     if(record_start && record_start_ready) record_start<=0;
     if(good_report) timeout_count<=0;
     else if(!expired) timeout_count<=timeout_count+1'b1;
     if(flush) begin
       live_count<=0; record_valid<=0; modulation_valid<=0; record_start<=0; overflow<=0; overflow_blocked<=0;
       coord_initialized<=0; x_filtered<=0; y_filtered<=0; z_filtered<=0; note_zone_active<=0;
       live_x_anchor<=0; live_x_trigger_count<=0;
       live_rearmed<=0;
       live_z_pressed<=0; live_z_press_count<=0; live_z_release_count<=0;
       raw_x_previous<=0; raw_y_previous<=0; live_x_decoupled<=0; live_y_decoupled<=0; motion_axis<=0;
       note_active<=0; record_active<=0; note_count<=0; cell_count<=0;
       cell_highwater<=0; cell_position<=0; cell_candidate<=0; start_history<=0;
       start_armed<=1; timeout_count<=0;
     end else if(!overflow_blocked) begin
       if(good_report) begin
         raw_x_previous<=x_position; raw_y_previous<=y_position;
         if(!coord_initialized) begin
           x_filtered<=x_position; y_filtered<=y_position; z_filtered<=z_position;
           live_x_decoupled<=x_position; live_y_decoupled<=y_position; motion_axis<=0;
           coord_initialized<=1;
         end else begin
           if(mode==MODE_LIVE) begin
             live_x_decoupled<=live_x_next; live_y_decoupled<=live_y_next; motion_axis<=next_axis;
           end else begin
             live_x_decoupled<=x_position; live_y_decoupled<=y_position; motion_axis<=0;
           end
           x_filtered<=smooth_coord(x_filtered,target_x);
           y_filtered<=smooth_coord(y_filtered,target_y);
           z_filtered<=coord_z;
         end
       end
       // Boundary completion takes priority over even a same-edge sensor report.
       if(prior_capture && !capturing) begin
         release_note(mode==MODE_COMMIT_PENDING);
       end else if((note_active && !performing) || release_report || (expired && note_active)) begin
         release_note(0);
         live_z_pressed<=0; live_z_press_count<=0; live_z_release_count<=0; live_x_trigger_count<=0;
         if(release_report || expired) coord_initialized<=0;
         if(mode==MODE_PLAY) begin
           modulation_valid<=1; modulation_event<=64'h0;
           modulation_event[2:0]<=EVENT_CONTROL_POINT;
           modulation_event[49:42]<=128; modulation_event[57:50]<=128;
         end
       end else if(expired || (prior_mode==MODE_PLAY && mode!=MODE_PLAY && mode!=MODE_OVERDUB_ARMED)) begin
         modulation_valid<=0;
       end else if(good_report) begin
         if(outputs_blocked && mode!=MODE_LIVE) safe_overflow();
         else begin
           if(mode==MODE_RECORD_ARMED) begin
             start_history<=next_history;
             if(!start_armed && coord_x>=start_exit) begin start_armed<=1; start_history<=0; end
             if(start_armed && majority) begin record_start<=1; start_armed<=0; start_history<=0; end
           end
           if(mode==MODE_LIVE && !live_y_valid) begin
             // The cropped top/bottom bands are dead zones, not notes.
             // Leaving the active band releases LIVE cleanly and requires a
             // fresh in-band Y selection before another note can start.
             if(note_active) release_note(0);
             note_count<=0; live_z_pressed<=0; live_z_press_count<=0; live_z_release_count<=0; live_x_trigger_count<=0;
           end else if(performing) begin
             if(next_note==note_candidate) begin if(note_count<NOTE_CONFIRM) note_count<=note_count+1'b1; end
             else begin note_candidate<=next_note; note_count<=1; end
             if(next_cell==cell_candidate) begin if(cell_count<CELL_CONFIRM) cell_count<=cell_count+1'b1; end
             else begin cell_candidate<=next_cell; cell_count<=1; end
             if(cell_confirmed) begin
               cell_position<=next_cell;
               if(coord_x<=start_enter) cell_highwater<=next_cell;
               else if(next_cell>cell_highwater) cell_highwater<=next_cell;
             end
             if(mode==MODE_LIVE) begin
               if(live_z_release_sample) begin
                 if(live_z_release_count<LIVE_Z_RELEASE_CONFIRM) live_z_release_count<=live_z_release_count+1'b1;
                 live_z_press_count<=0;
               end else if(live_z_press_sample) begin
                 if(live_z_press_count<LIVE_Z_PRESS_CONFIRM) live_z_press_count<=live_z_press_count+1'b1;
                 live_z_release_count<=0;
               end else begin live_z_press_count<=0; live_z_release_count<=0; end
               if(!live_z_pressed && live_z_press_sample && live_z_press_confirmed) live_z_pressed<=1;
               if(live_z_releasing) begin
                 if(note_active) live_one(event_word(EVENT_NOTE_OFF,active_note,active_track));
                 note_active<=0; live_x_trigger_count<=0;
                 live_z_pressed<=0; live_z_press_count<=0; live_z_release_count<=0; live_rearmed<=0;
               end
               if(coord_x<=start_enter) live_rearmed<=1;
               // LIVE separates vertical note selection from horizontal
               // triggering. The first confirmed note starts immediately;
               // later Y changes wait for a debounced X displacement.
               if(live_z_gate && note_confirmed && !note_active) begin
                 live_one(event_word(EVENT_NOTE_ON,next_note,selected_track));
                 active_note<=next_note; active_track<=selected_track; note_zone_active<=next_note_zone; note_active<=1;
                 live_x_anchor<=coord_x; live_x_trigger_count<=0; last_expression<=z_level;
               end else if(live_z_gate && note_confirmed && note_active && next_note!=active_note) begin
                 if(live_x_far) begin
                   if(live_x_trigger_count < LIVE_X_TRIGGER_CONFIRM) live_x_trigger_count<=live_x_trigger_count+1'b1;
                 end else live_x_trigger_count<=0;
                 if(live_x_far && ((live_x_trigger_count+1)>=LIVE_X_TRIGGER_CONFIRM)) begin
                   live_pair(event_word(EVENT_NOTE_OFF,active_note,active_track),event_word(EVENT_NOTE_ON,next_note,selected_track));
                   active_note<=next_note; active_track<=selected_track; note_zone_active<=next_note_zone;
                   live_x_anchor<=coord_x; live_x_trigger_count<=0; live_rearmed<=0; last_expression<=z_level;
                 end
               end else if(live_z_gate && note_active && live_rearmed && live_x_far && note_confirmed) begin
                 if(live_x_trigger_count<LIVE_X_TRIGGER_CONFIRM) live_x_trigger_count<=live_x_trigger_count+1'b1;
                 if((live_x_trigger_count+1)>=LIVE_X_TRIGGER_CONFIRM) begin
                   live_pair(event_word(EVENT_NOTE_OFF,active_note,active_track),event_word(EVENT_NOTE_ON,active_note,selected_track));
                   live_x_anchor<=coord_x; live_x_trigger_count<=0; live_rearmed<=0; last_expression<=z_level;
                 end
               end else if(live_z_gate && note_active && last_expression!=z_level) begin
                 live_one(event_word(EVENT_CONTROL_POINT,active_note,active_track));
                 last_expression<=z_level;
               end
               if(!live_x_far || !note_confirmed) live_x_trigger_count<=0;
             end else if(note_confirmed && (!note_active || next_note!=active_note)) begin
               if(note_active) live_pair(event_word(EVENT_NOTE_OFF,active_note,active_track),event_word(EVENT_NOTE_ON,next_note,selected_track));
               else live_one(event_word(EVENT_NOTE_ON,next_note,selected_track));
               close_record(0);
               active_note<=next_note; active_track<=selected_track; note_zone_active<=next_note_zone; note_active<=1;
               if(capturing) begin record_note<=event_word(EVENT_NOTE_ON,next_note,selected_track); record_active<=1; end
               last_expression<=z_level;
             end else if(note_active && forward_cross) begin
               live_pair(event_word(EVENT_NOTE_OFF,active_note,active_track),event_word(EVENT_NOTE_ON,active_note,active_track));
               if(capturing && (!record_active || record_note[11:5]!=loop_tick)) begin
                 close_record(0); record_note<=event_word(EVENT_NOTE_ON,active_note,active_track); record_active<=1;
               end
               last_expression<=z_level;
             end else if(note_active && last_expression!=z_level) begin
               live_one(event_word(EVENT_CONTROL_POINT,active_note,active_track));
               last_expression<=z_level;
               if(record_active) begin
                 record_note[33:26]<=map_velocity(coord_z);
                 record_note[49:42]<=z_level; record_note[57:50]<=z_level;
               end
             end
           end else if(mode==MODE_PLAY || mode==MODE_OVERDUB_ARMED) begin
             modulation_valid<=1; modulation_event<=event_word(EVENT_CONTROL_POINT,0,selected_track);
             modulation_event[41:34]<={1'b0,coord_x[15:9]}-8'd64;
             modulation_event[49:42]<=z_level; modulation_event[57:50]<=coord_y[15:8];
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
