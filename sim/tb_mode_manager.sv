`timescale 1ns/1ps
module tb_mode_manager;
 import control_protocol_pkg::*;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0, cmd_valid=0, rsp_ready=0, urgent_stop=0;
 reg [7:0] cmd_opcode=0; reg [15:0] cmd_arg0=0,cmd_arg1=0;
 wire cmd_ready,rsp_valid; wire [7:0] rsp_status; wire [31:0] rsp_data;
 reg record_start=0,sixteenth_ce=0,loop_boundary=0;
 reg [6:0] loop_tick=0;
 reg [15:0] scheduler_active_bpm=120;
 reg scheduler_fault=0,store_ctrl_ready=1,store_ctrl_done=0;
 reg store_commit_pending=0,store_commit_ack=0,store_active_valid=1,store_busy=0;
 reg [19:0] store_record_count=0; reg [3:0] store_overflow=0;
 reg router_idle=1,record_accepted=0,kill_ready=1;
 wire store_ctrl_valid,store_abort,store_boundary,scheduler_run,scheduler_stop,scheduler_reset;
 wire [2:0] store_ctrl_op; wire [1:0] store_ctrl_track;
 wire boundary_ready,kill_valid,flush_events;
 wire [3:0] mode; wire [1:0] selected_track;
 wire [15:0] bpm_shadow,start_enter,start_exit;
 wire live_enable,record_enable,play_enable,fault_latched;
 mode_manager #(.OP_TIMEOUT_CYCLES(40),.BOUNDARY_TIMEOUT_CYCLES(100)) dut(.*);
 integer cycles=0,ops=0,i; reg emulate_store=1; reg [2:0] last_op;
 reg stalled_ctrl=0,stalled_rsp=0; reg [4:0] held_ctrl; reg [39:0] held_rsp;
 always @(posedge clk) if(rst_n) begin
   if(stalled_ctrl && !urgent_stop && !scheduler_fault && !store_abort &&
      (!store_ctrl_valid || {store_ctrl_op,store_ctrl_track}!==held_ctrl))
     $fatal(1,"control changed under backpressure");
   if(stalled_rsp && (!rsp_valid || {rsp_status,rsp_data}!==held_rsp))
     $fatal(1,"response changed under backpressure");
   stalled_ctrl<=store_ctrl_valid && !store_ctrl_ready;
   held_ctrl<={store_ctrl_op,store_ctrl_track};
   stalled_rsp<=rsp_valid && !rsp_ready;
   held_rsp<={rsp_status,rsp_data};
 end
 always @(posedge clk) begin
   cycles<=cycles+1; store_ctrl_done<=0; store_commit_ack<=0;
   if(store_abort) begin store_commit_pending<=0; store_busy<=0; end
   else if(emulate_store) begin
     if(store_ctrl_valid && store_ctrl_ready) begin
       store_ctrl_done<=1; ops<=ops+1; last_op<=store_ctrl_op;
       if(store_ctrl_op==3) begin store_commit_pending<=1; store_busy<=1; end
     end
     if(store_boundary && store_commit_pending) begin
       store_commit_pending<=0; store_commit_ack<=1; store_busy<=0;
     end
   end
   if(cycles>3000) $fatal(1,"watchdog");
 end
 task step(input integer n); repeat(n) begin @(posedge clk); #1; end endtask
 task send(input [7:0] op,input [15:0] a,input [15:0] b);
   begin
     @(negedge clk); cmd_opcode=op; cmd_arg0=a; cmd_arg1=b; cmd_valid=1;
     do begin @(posedge clk); end while(!cmd_ready);
     @(negedge clk); cmd_valid=0;
   end
 endtask
 task ack(input [7:0] status);
   begin
     while(!rsp_valid) step(1);
     if(rsp_status!==status) $fatal(1,"ack got %d expected %d mode %d",rsp_status,status,mode);
     @(negedge clk); rsp_ready=1; step(1); @(negedge clk); rsp_ready=0;
   end
 endtask
 task tick(input [6:0] t);
   begin @(negedge clk); loop_tick=t; sixteenth_ce=1; step(1); @(negedge clk); sixteenth_ce=0; end
 endtask
 task boundary;
   begin @(negedge clk); loop_boundary=1; step(1); @(negedge clk); loop_boundary=0; end
 endtask
 task capture;
   begin @(negedge clk); record_accepted=1; step(1); @(negedge clk); record_accepted=0; end
 endtask
 initial begin
   step(2); rst_n=1; step(2);
   if(mode!==MODE_IDLE || bpm_shadow!==120 || start_enter!==16'h2000) $fatal(1,"defaults");
   store_active_valid=0; send(CMD_PLAY,0,0); ack(ACK_REJECTED); store_active_valid=1;
   send(CMD_SET_BPM,59,0); ack(ACK_REJECTED);
   send(CMD_SET_THRESHOLDS,200,100); ack(ACK_REJECTED);
   send(CMD_SET_MODE,MODE_LIVE,0); ack(ACK_APPLIED);
   if(!live_enable) $fatal(1,"live");
   send(CMD_SELECT_TRACK,2,0); ack(ACK_APPLIED);
   send(CMD_RECORD,0,0); ack(ACK_APPLIED);
   if(mode!=MODE_RECORD_ARMED || last_op!=5 || store_ctrl_track!=2) $fatal(1,"record prepare");
   send(CMD_SELECT_TRACK,1,0); ack(ACK_BUSY);
   send(CMD_SET_BPM,130,0); ack(ACK_BUSY);
   if(bpm_shadow!=120) $fatal(1,"record armed tempo changed");
   @(negedge clk); record_start=1; step(1); @(negedge clk); record_start=0;
   tick(0);
   if(mode!=MODE_RECORDING || !record_enable || boundary_ready || play_enable) $fatal(1,"first tick");
   send(CMD_SET_BPM,130,0); ack(ACK_BUSY);
   for(i=1;i<128;i=i+1) begin
     tick(i[6:0]);
     if(mode!=MODE_RECORDING || !record_enable) $fatal(1,"phrase ended early at %d",i);
   end
   router_idle=0; tick(0); step(3);
   if(record_enable || boundary_ready || play_enable || mode!=MODE_COMMIT_PENDING) $fatal(1,"drain boundary guard");
   capture(); // Last accepted RAM write can arrive after input capture closes.
   send(CMD_COMMIT,0,0); step(2); if(rsp_valid) $fatal(1,"commit premature ack");
   router_idle=1; step(8);
   if(!boundary_ready || !store_commit_pending) $fatal(1,"commit prepare");
   boundary(); ack(ACK_APPLIED); step(4);
   if(mode!=MODE_PLAY || !play_enable) $fatal(1,"commit to play");
   send(CMD_SET_BPM,150,0); step(3); if(rsp_valid) $fatal(1,"tempo premature");
   scheduler_active_bpm=150; boundary(); ack(ACK_APPLIED);
   send(CMD_SET_BPM,151,0); ack(ACK_ERROR); step(3);
   if(mode!=MODE_IDLE || scheduler_run) $fatal(1,"boundary timeout");
   if(bpm_shadow!=150) $fatal(1,"timeout must roll back unapplied BPM");
   send(CMD_PLAY,0,0); ack(ACK_APPLIED);
   send(CMD_SET_BPM,152,0); step(3);
   urgent_stop=1; step(2); ack(ACK_ERROR);
   if(bpm_shadow!=150) $fatal(1,"STOP must roll back unapplied BPM");
   urgent_stop=0; step(3);
   send(CMD_PLAY,0,0); ack(ACK_APPLIED);
   send(CMD_SET_BPM,153,0); step(3);
   scheduler_fault=1; step(2); ack(ACK_ERROR);
   if(bpm_shadow!=150) $fatal(1,"fault must roll back unapplied BPM");
   scheduler_fault=0; step(3);
   send(CMD_PLAY,0,0); ack(ACK_APPLIED);
   send(CMD_SET_BPM,154,0); step(3);
   // The scheduler latches tempo at the musical deadline, before its accepted
   // LOOP_BOUNDARY marker. Cancellation after that latch must retain it.
   scheduler_active_bpm=154; urgent_stop=1; step(2); ack(ACK_ERROR);
   if(bpm_shadow!=154) $fatal(1,"STOP must retain already latched BPM");
   urgent_stop=0; step(3);
   send(CMD_PLAY,0,0); ack(ACK_APPLIED);
   send(CMD_OVERDUB,0,0); ack(ACK_APPLIED);
   if(mode!=MODE_OVERDUB_ARMED || !play_enable) $fatal(1,"overdub arm");
   send(CMD_SET_BPM,155,0); ack(ACK_BUSY);
   if(bpm_shadow!=154) $fatal(1,"overdub armed tempo changed");
   boundary(); step(1); if(mode!=MODE_OVERDUB || !record_enable) $fatal(1,"overdub begin");
   send(CMD_SET_BPM,155,0); ack(ACK_BUSY);
   tick(0); step(8); if(mode!=MODE_IDLE || scheduler_run) $fatal(1,"empty overdub abort");
   send(CMD_CLEAR_ALL,0,0); ack(ACK_APPLIED);
   if(mode!=MODE_IDLE || store_commit_pending) $fatal(1,"clear manual boundary");
   send(CMD_PLAY,0,0); ack(ACK_APPLIED);
   kill_ready=0; send(CMD_STOP,0,0); step(4);
   if(scheduler_run || !kill_valid || rsp_valid) $fatal(1,"stop waits kill");
   kill_ready=1; ack(ACK_APPLIED);
   emulate_store=0; store_ctrl_ready=0;
   send(CMD_RECORD,0,0); step(6); urgent_stop=1; step(2);
   if(scheduler_run || mode!=MODE_IDLE) $fatal(1,"urgent preempt");
   ack(ACK_ERROR); step(3);
   send(CMD_PLAY,0,0); ack(ACK_ERROR);
   urgent_stop=0; step(2); emulate_store=1; store_ctrl_ready=1;
   send(CMD_SET_BPM,160,0); while(!rsp_valid) step(1);
   urgent_stop=1; step(4);
   if(!rsp_valid || rsp_status!=ACK_APPLIED || rsp_data!=0) $fatal(1,"immutable response");
   ack(ACK_APPLIED); urgent_stop=0; step(3);
   emulate_store=0; store_ctrl_ready=0;
   send(CMD_RECORD,0,0); ack(ACK_ERROR); step(4);
   if(mode!=MODE_IDLE || scheduler_run || !fault_latched) $fatal(1,"timeout recover");
   send(CMD_RESET,0,0); ack(ACK_APPLIED);
   if(fault_latched) $fatal(1,"reset fault");
   emulate_store=1; store_ctrl_ready=1;
   send(CMD_RECORD,0,0); ack(ACK_APPLIED);
   @(negedge clk); record_start=1; step(1); @(negedge clk); record_start=0;
   tick(0); capture(); store_overflow=4'b0100; step(4);
   if(mode!=MODE_IDLE || scheduler_run || !fault_latched || store_commit_pending)
     $fatal(1,"overflow must abort take");
   store_overflow=0;
   send(CMD_RESET,0,0); ack(ACK_APPLIED);
   scheduler_fault=1; step(4);
   if(!fault_latched || mode!=MODE_IDLE) $fatal(1,"scheduler fault");
   $display("tb_mode_manager PASS"); $finish;
 end
endmodule
