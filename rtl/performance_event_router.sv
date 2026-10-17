module performance_event_router(
 input wire clk,rst_n,flush,
 input wire live_enable,record_enable,play_enable,
 input wire [1:0] selected_track,input wire [6:0] loop_tick,
 input wire [19:0] store_record_count,
 input wire in_valid,output wire in_ready,input wire [63:0] in_data,
 input wire sched_valid,output wire sched_ready,input wire [63:0] sched_data,
 input wire kill_valid,output wire kill_ready,
 output wire out_valid,input wire out_ready,output wire [63:0] out_data,
 output wire write_valid,input wire write_ready,output wire [1:0] write_track,
 output wire [3:0] write_slot,output wire [63:0] write_data,
 output wire idle,output reg record_accepted,output reg record_overflow
);
 import performance_event_pkg::*;
 reg monitor_pending,record_pending,output_pending;
 reg [63:0] monitor_data,record_data,output_data;
 reg [1:0] record_track;
 reg [3:0] record_slot;
 wire output_room=!output_pending || out_ready;
 wire [4:0] selected_count=store_record_count[selected_track*5 +: 5];
 wire record_only=in_data[61];
 wire recordable=(in_data[2:0]==EVENT_NOTE_ON ||
                  in_data[2:0]==EVENT_NOTE_OFF ||
                  in_data[2:0]==EVENT_CONTROL_POINT);
 // Completed record tails may arrive after the manager enters COMMIT_PENDING
 // and disables live_enable; their flag makes them storage-only and safe here.
 assign in_ready=!flush && (live_enable || record_only) && !kill_valid && !monitor_pending && !record_pending;
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
   if(in_valid && in_ready)begin
    if(!record_only) begin
     monitor_pending<=1;
     monitor_data<={in_data[63:5],selected_track,in_data[2:0]};
    end
    if((record_enable || record_only) && recordable)begin
     if(selected_count>=16)record_overflow<=1;
     else begin
      record_pending<=1;record_track<=record_only ? in_data[4:3] : selected_track;
      record_slot<=selected_count[3:0];
      record_data<=record_only ? in_data : {in_data[63:12],loop_tick,selected_track,in_data[2:0]};
     end
    end
   end
  end
 end
endmodule
