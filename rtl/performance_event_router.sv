module performance_event_router #(
 parameter integer SPLIT_INPUTS=0
)(
 input wire clk,rst_n,flush,
 input wire live_enable,record_enable,play_enable,
 input wire [1:0] selected_track,input wire [6:0] loop_tick,
 input wire [19:0] store_record_count,
 input wire in_valid,output wire in_ready,input wire [63:0] in_data,
 input wire live_in_valid,output wire live_in_ready,input wire [63:0] live_in_data,
 input wire record_in_valid,output wire record_in_ready,input wire [63:0] record_in_data,
 input wire sched_valid,output wire sched_ready,input wire [63:0] sched_data,
 input wire kill_valid,output wire kill_ready,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,
 output wire write_valid,input wire write_ready,output wire [1:0] write_track,
 output wire [3:0] write_slot,output wire [63:0] write_data,
 output wire idle,output reg record_accepted,output reg record_overflow
 ,output wire [2:0] pending_debug
);
 import performance_event_pkg::*;
 reg monitor_pending,record_pending,output_pending;
 reg [63:0] monitor_data,record_data,output_data;
 reg [1:0] record_track;
 reg [3:0] record_slot;
 wire output_room=!output_pending || out_ready;
 wire split_record_valid = SPLIT_INPUTS ? record_in_valid : 1'b0;
 wire split_live_valid = SPLIT_INPUTS ? live_in_valid : 1'b0;
 wire source_valid = SPLIT_INPUTS ? (split_record_valid || split_live_valid) : in_valid;
 wire source_is_record = SPLIT_INPUTS ? split_record_valid : in_data[61];
 wire [63:0] source_data = SPLIT_INPUTS ? (split_record_valid ? record_in_data : live_in_data) : in_data;
 wire [4:0] selected_count=store_record_count[selected_track*5 +: 5];
 wire record_only=source_is_record;
 wire recordable=(source_data[2:0]==EVENT_NOTE_ON ||
                  source_data[2:0]==EVENT_NOTE_OFF ||
                  source_data[2:0]==EVENT_CONTROL_POINT);
 // Completed record tails may arrive after the manager enters COMMIT_PENDING
 // and disables live_enable; their flag makes them storage-only and safe here.
 // A monitor event may be retired to the output register on this same edge.
 // Allow a simultaneous input handshake when that output slot is available;
 // otherwise the upstream mux sees a permanent two-stage ready/valid bubble.
 wire legacy_ready=!flush && (live_enable || record_only) && !kill_valid &&
                 (!record_pending) && (!monitor_pending || output_room);
 wire split_live_ready=!flush && live_enable && !kill_valid && !split_record_valid &&
                 (!monitor_pending || output_room);
 wire split_record_ready=!flush && !record_pending;
 assign in_ready=SPLIT_INPUTS ? 1'b0 : legacy_ready;
 assign live_in_ready=SPLIT_INPUTS ? split_live_ready : 1'b0;
 assign record_in_ready=SPLIT_INPUTS ? split_record_ready : 1'b0;
 assign write_valid=!flush && record_pending;
 assign write_track=record_track;
 assign write_slot=record_slot;
 assign write_data=record_data;
 assign out_valid=!flush && output_pending;
 assign out_data=output_data;
 // A kill handshake means ALL_NOTES_OFF is buffered, ordered after the
 // already presented event and before future live/scheduler arbitration.
 assign kill_ready=!flush && output_room;
 assign sched_ready=!flush && (!play_enable || (output_room && !kill_valid && !monitor_pending));
 assign idle=!monitor_pending && !record_pending && !output_pending;
 assign pending_debug={monitor_pending,record_pending,output_pending};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   monitor_pending<=0;record_pending<=0;output_pending<=0;
   monitor_data<=0;record_data<=0;output_data<=0;record_track<=0;record_slot<=0;
   record_accepted<=0;record_overflow<=0;
  end else if(flush)begin
   monitor_pending<=0;record_pending<=0;output_pending<=0;
   record_accepted<=0;record_overflow<=0;
  end else begin
   record_accepted<=write_valid && write_ready;
   if(write_valid && write_ready)record_pending<=0;
   if(output_room)begin
    output_pending<=0;
    if(kill_valid)begin
     output_pending<=1;output_data<={61'd0,EVENT_ALL_NOTES_OFF};
    end else if(monitor_pending)begin
     output_pending<=1;output_data<=monitor_data;monitor_pending<=0;
    end else if(play_enable && sched_valid)begin
     output_pending<=1;output_data<=sched_data;
    end
   end
   if(source_valid && (SPLIT_INPUTS ? (source_is_record ? record_in_ready : live_in_ready) : in_ready))begin
    if(!record_only) begin
     monitor_pending<=1;
     monitor_data<={source_data[63:5],selected_track,source_data[2:0]};
    end
    if((record_enable || record_only) && recordable)begin
     if(selected_count>=16)record_overflow<=1;
     else begin
      record_pending<=1;record_track<=record_only ? source_data[4:3] : selected_track;
      record_slot<=selected_count[3:0];
      record_data<=record_only ? source_data : {source_data[63:12],loop_tick,selected_track,source_data[2:0]};
     end
    end
   end
  end
 end
endmodule
