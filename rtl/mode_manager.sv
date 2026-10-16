// Control-only loop lifecycle. Audio/event datapaths live in the router/store.
module mode_manager #(
 parameter integer OP_TIMEOUT_CYCLES=50000000,
 parameter integer BOUNDARY_TIMEOUT_CYCLES=1700000000
)(
 input wire clk,rst_n,
 input wire cmd_valid, output wire cmd_ready,
 input wire [7:0] cmd_opcode, input wire [15:0] cmd_arg0,cmd_arg1,
 output reg rsp_valid, input wire rsp_ready,
 output reg [7:0] rsp_status, output reg [31:0] rsp_data,
 input wire urgent_stop,record_start,sixteenth_ce,
 input wire [6:0] loop_tick, input wire loop_boundary,
 input wire [15:0] scheduler_active_bpm, input wire scheduler_fault,
 input wire store_ctrl_ready,store_ctrl_done,store_commit_pending,store_commit_ack,
 input wire store_active_valid,store_busy,
 input wire [19:0] store_record_count, input wire [3:0] store_overflow,
 input wire router_idle,record_accepted,
 output wire store_ctrl_valid, output reg [2:0] store_ctrl_op,
 output wire [1:0] store_ctrl_track, output reg store_abort,
 output wire store_boundary,
 output reg scheduler_run,scheduler_stop,scheduler_reset,
 output wire boundary_ready,output wire kill_valid,input wire kill_ready,
 output reg flush_events, output reg [3:0] mode,
 output reg [1:0] selected_track,
 output reg [15:0] bpm_shadow,start_enter,start_exit,
 output wire live_enable,record_enable,play_enable,output reg fault_latched
);
 import control_protocol_pkg::*;
 localparam [3:0] S_IDLE=0,S_KILL=1,S_REQUEST=2,S_DONE=3,S_PENDING=4,
                  S_COMMIT=5,S_DRAIN=6,S_BPM=7;
 localparam [2:0] A_STOP=0,A_PLAY=1,A_RECORD=2,A_OVERDUB=3,A_CLEAR=4,A_FINISH=5;
 reg [3:0] state;
 reg [2:0] action;
 reg command_pending,urgent_d,fault_seen,first_record_tick,recorded;
 reg manual_boundary,bpm_boundary_seen,capture_playback;
 reg [15:0] bpm_previous;
 reg [31:0] watchdog,boundary_watchdog;
 wire capture_fault=(mode==MODE_RECORDING || mode==MODE_OVERDUB || mode==MODE_COMMIT_PENDING) && (|store_overflow);
 wire cancelling=(urgent_stop && !urgent_d) || (scheduler_fault && !fault_seen) || capture_fault;
 assign cmd_ready=rst_n && (state==S_IDLE || mode==MODE_COMMIT_PENDING) && !command_pending && !rsp_valid && !cancelling;
 assign store_ctrl_valid=rst_n && state==S_REQUEST && !cancelling;
 assign store_ctrl_track=selected_track;
 assign kill_valid=rst_n && state==S_KILL;
 assign boundary_ready=!(mode==MODE_RECORDING || mode==MODE_OVERDUB ||
                         (mode==MODE_COMMIT_PENDING && state!=S_COMMIT));
 assign store_boundary=(loop_boundary && scheduler_run && !cancelling) || manual_boundary;
 assign live_enable=!urgent_stop && (mode==MODE_LIVE || mode==MODE_RECORDING || mode==MODE_OVERDUB);
 assign record_enable=!urgent_stop && (mode==MODE_RECORDING || mode==MODE_OVERDUB);
 assign play_enable=!urgent_stop && (mode==MODE_PLAY || mode==MODE_OVERDUB_ARMED || mode==MODE_OVERDUB ||
                                    (mode==MODE_COMMIT_PENDING && capture_playback));
 // Reply storage is independent from cleanup: urgent cancellation never edits a
 // previously published response, even when its consumer is backpressured.
 task reply(input [7:0] status);
 begin rsp_valid<=1; rsp_status<=status; rsp_data<=0; command_pending<=0; end
 endtask
 task stop_now;
 begin
   // active_bpm is the scheduler's authoritative musical-deadline latch.
   // The accepted LOOP_BOUNDARY marker can lag that latch under backpressure.
   // Roll back only an unapplied proposal; never undo an already heard tempo.
   if(state==S_BPM && scheduler_active_bpm!=bpm_shadow) bpm_shadow<=bpm_previous;
   store_abort<=1; scheduler_run<=0; scheduler_stop<=1; flush_events<=1;
   mode<=MODE_IDLE; state<=S_KILL; action<=A_STOP; watchdog<=0;
 end
 endtask
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     rsp_valid<=0; rsp_status<=0; rsp_data<=0; state<=S_IDLE; action<=A_STOP;
     command_pending<=0; urgent_d<=0; fault_seen<=0; first_record_tick<=0; recorded<=0;
     manual_boundary<=0; bpm_boundary_seen<=0; capture_playback<=0; watchdog<=0; boundary_watchdog<=0;
     store_ctrl_op<=0; store_abort<=0; scheduler_run<=0; scheduler_stop<=0;
     scheduler_reset<=0; flush_events<=0; mode<=MODE_IDLE; selected_track<=0;
     bpm_shadow<=120; bpm_previous<=120; start_enter<=16'h2000; start_exit<=16'h3000; fault_latched<=0;
   end else begin
     urgent_d<=urgent_stop;
     if(scheduler_fault) fault_seen<=1;
     else fault_seen<=0;
     store_abort<=0; scheduler_stop<=0; scheduler_reset<=0; flush_events<=0; manual_boundary<=0;
     if(rsp_valid && rsp_ready) rsp_valid<=0;
     if((record_enable || state==S_DRAIN) && record_accepted) recorded<=1;
     // Musical time itself is not an operation timeout. S_BPM can legitimately
     // last a complete 128-sixteenth phrase, longer than a store watchdog.
     if(state!=S_IDLE && state!=S_BPM) watchdog<=watchdog+1; else watchdog<=0;
     if(state==S_BPM || mode==MODE_OVERDUB_ARMED) boundary_watchdog<=boundary_watchdog+1;
     else boundary_watchdog<=0;
     if(cancelling) begin
       stop_now();
       if((scheduler_fault && !fault_seen) || capture_fault) fault_latched<=1;
       if(command_pending) reply(ACK_ERROR);
     end else if((state!=S_IDLE && state!=S_BPM && watchdog>=OP_TIMEOUT_CYCLES-1) ||
                 ((state==S_BPM || mode==MODE_OVERDUB_ARMED) && boundary_watchdog>=BOUNDARY_TIMEOUT_CYCLES-1)) begin
       stop_now(); fault_latched<=1;
       boundary_watchdog<=0;
       if(command_pending) reply(ACK_ERROR);
       // Remain physically stopped even if downstream never accepts kill.
     end else begin
       case(state)
         S_KILL: if(kill_ready) begin
           watchdog<=0;
           case(action)
             A_RECORD: begin store_ctrl_op<=5; state<=S_REQUEST; end
             A_PLAY: begin mode<=MODE_PLAY; scheduler_run<=1; state<=S_IDLE; reply(ACK_APPLIED); end
             default: begin state<=S_IDLE; if(command_pending) reply(ACK_APPLIED); end
           endcase
         end
         S_REQUEST: if(store_ctrl_ready) begin
           watchdog<=0;
           if(store_ctrl_done) begin
             if(store_ctrl_op==3) state<=S_PENDING;
             else if(action==A_CLEAR) begin store_ctrl_op<=3; state<=S_REQUEST; end
             else begin
               mode<=(action==A_RECORD)?MODE_RECORD_ARMED:MODE_OVERDUB_ARMED;
               state<=S_IDLE; reply(ACK_APPLIED);
             end
           end else state<=S_DONE;
         end
         S_DONE: if(store_ctrl_done) begin
           watchdog<=0;
           if(store_ctrl_op==3) state<=S_PENDING;
           else if(action==A_CLEAR) begin store_ctrl_op<=3; state<=S_REQUEST; end
           else begin
             mode<=(action==A_RECORD)?MODE_RECORD_ARMED:MODE_OVERDUB_ARMED;
             state<=S_IDLE; reply(ACK_APPLIED);
           end
         end
         S_PENDING: if(store_commit_pending) begin
           state<=S_COMMIT; watchdog<=0;
           if(action==A_CLEAR) manual_boundary<=1;
         end
         S_COMMIT: if(store_commit_ack) begin
           state<=S_IDLE; watchdog<=0;
           if(action!=A_CLEAR) mode<=MODE_PLAY;
           if(command_pending) reply(ACK_APPLIED);
         end
         S_DRAIN: if(router_idle) begin
           watchdog<=0;
           if(!recorded && !record_accepted) stop_now();
           else begin store_ctrl_op<=3; state<=S_REQUEST; end
         end
         S_BPM: begin
           if(loop_boundary) bpm_boundary_seen<=1;
           if((bpm_boundary_seen || loop_boundary) && scheduler_active_bpm==bpm_shadow) begin
             state<=S_IDLE; reply(ACK_APPLIED);
           end
         end
         default: begin
           if(mode==MODE_RECORD_ARMED && record_start && !urgent_stop) begin
             mode<=MODE_RECORDING; scheduler_run<=1; first_record_tick<=1; recorded<=0;
           end
           if(mode==MODE_OVERDUB_ARMED && loop_boundary) begin
             mode<=MODE_OVERDUB; first_record_tick<=0; recorded<=0;
           end
           if((mode==MODE_RECORDING || mode==MODE_OVERDUB) && sixteenth_ce && loop_tick==0) begin
             if(first_record_tick) first_record_tick<=0;
             else begin mode<=MODE_COMMIT_PENDING; state<=S_DRAIN; action<=A_FINISH; end
           end
           if(cmd_valid && cmd_ready) begin
             command_pending<=1;
             if(urgent_stop && cmd_opcode!=CMD_STOP && cmd_opcode!=CMD_RESET &&
                !(cmd_opcode==CMD_SET_MODE && cmd_arg0==MODE_IDLE)) reply(ACK_ERROR);
             else case(cmd_opcode)
               CMD_STOP,CMD_RESET: begin
                 if(cmd_arg0!=0 || cmd_arg1!=0) reply(ACK_REJECTED);
                 else begin
                   stop_now();
                   if(cmd_opcode==CMD_RESET) begin fault_latched<=0; scheduler_reset<=1; fault_seen<=scheduler_fault; end
                 end
               end
               CMD_SET_MODE: begin
                 if(cmd_arg1!=0 || (cmd_arg0!=MODE_IDLE && cmd_arg0!=MODE_LIVE)) reply(ACK_REJECTED);
                 else if(cmd_arg0==MODE_IDLE) stop_now();
                 else if(mode!=MODE_IDLE) reply(ACK_BUSY);
                 else begin mode<=MODE_LIVE; reply(ACK_APPLIED); end
               end
               CMD_SET_BPM: begin
                 if(cmd_arg0<60 || cmd_arg0>180 || cmd_arg1!=0) reply(ACK_REJECTED);
                 else if(mode==MODE_RECORD_ARMED || mode==MODE_OVERDUB_ARMED ||
                         mode==MODE_RECORDING || mode==MODE_OVERDUB || mode==MODE_COMMIT_PENDING) reply(ACK_BUSY);
                 else begin
                   bpm_shadow<=cmd_arg0;
                   if(mode==MODE_PLAY) begin state<=S_BPM; bpm_boundary_seen<=0; bpm_previous<=bpm_shadow; end
                   else reply(ACK_APPLIED);
                 end
               end
               CMD_SELECT_TRACK: begin
                 if(cmd_arg0>3 || cmd_arg1!=0) reply(ACK_REJECTED);
                 else if(mode!=MODE_IDLE && mode!=MODE_LIVE && mode!=MODE_PLAY) reply(ACK_BUSY);
                 else begin selected_track<=cmd_arg0[1:0]; reply(ACK_APPLIED); end
               end
               CMD_SET_THRESHOLDS: begin
                 if(cmd_arg0>=cmd_arg1) reply(ACK_REJECTED);
                 else if(mode!=MODE_IDLE && mode!=MODE_LIVE) reply(ACK_BUSY);
                 else begin start_enter<=cmd_arg0; start_exit<=cmd_arg1; reply(ACK_APPLIED); end
               end
               CMD_RECORD,CMD_PLAY,CMD_OVERDUB,CMD_CLEAR_TRACK,CMD_CLEAR_ALL: begin
                 if(cmd_arg0!=0 || cmd_arg1!=0) reply(ACK_REJECTED);
                 else case(cmd_opcode)
                   CMD_RECORD: if(mode!=MODE_IDLE && mode!=MODE_LIVE) reply(ACK_BUSY);
                     else begin stop_now(); action<=A_RECORD; capture_playback<=0; end
                   CMD_PLAY: if(mode!=MODE_IDLE) reply(ACK_BUSY);
                     else if(!store_active_valid) reply(ACK_REJECTED);
                     else begin stop_now(); action<=A_PLAY; end
                   CMD_OVERDUB: if(mode!=MODE_PLAY) reply(ACK_BUSY);
                     else begin action<=A_OVERDUB; capture_playback<=1; store_ctrl_op<=0; state<=S_REQUEST; end
                   default: if(mode!=MODE_IDLE) reply(ACK_BUSY);
                     else begin action<=A_CLEAR; store_ctrl_op<=(cmd_opcode==CMD_CLEAR_ALL)?2:5; state<=S_REQUEST; end
                 endcase
               end
               default: reply(ACK_REJECTED);
             endcase
           end
         end
       endcase
       // COMMIT observes the automatic fixed-phrase finalization; it never
       // shortens capture or issues a second store operation.
       if(cmd_valid && cmd_ready && state!=S_IDLE) begin
         command_pending<=1;
         if(cmd_arg0!=0 || cmd_arg1!=0) reply(ACK_REJECTED);
         else if(cmd_opcode==CMD_COMMIT) begin
           if(state==S_COMMIT && store_commit_ack) reply(ACK_APPLIED);
         end else if(cmd_opcode==CMD_STOP || cmd_opcode==CMD_RESET) begin
           stop_now();
           if(cmd_opcode==CMD_RESET) begin fault_latched<=0; scheduler_reset<=1; fault_seen<=scheduler_fault; end
         end else reply(ACK_BUSY);
       end
     end
   end
 end
endmodule
