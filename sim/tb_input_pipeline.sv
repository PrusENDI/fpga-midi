`timescale 1ns/1ps
// Actual reader parser -> report latch -> event adapter. I2C transport is
// bypassed by frame injection, using the stub in tb_reader_touch.sv.
module tb_input_pipeline;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0;
 tri1 i2c_sda,i2c_scl,mgc_ts;
 wire report_valid,xyz_valid,report_error,touch_valid;
 wire [15:0] x_position,y_position,z_position;
 wire [7:0] gesture_code;
 wire [31:0] touch_info;
 wire report_valid_latched,report_error_latched,xyz_valid_latched,touch_valid_latched;
 wire [15:0] x_latched,y_latched,z_latched;
 wire [31:0] touch_info_latched;
 mgc3130_reader reader(.clk(clk),.rst_n(rst_n),.i2c_sda(i2c_sda),.i2c_scl(i2c_scl),.mgc_ts(mgc_ts),
   .report_valid(report_valid),.xyz_valid(xyz_valid),.report_error(report_error),
   .x_position(x_position),.y_position(y_position),.z_position(z_position),
   .gesture_code(gesture_code),.touch_valid(touch_valid),.touch_info(touch_info));
 mgc3130_input_latch latch(.clk(clk),.rst_n(rst_n),.report_valid(report_valid),.xyz_valid(xyz_valid),
   .report_error(report_error),.x_position(x_position),.y_position(y_position),.z_position(z_position),
   .gesture_code(gesture_code),.touch_valid(touch_valid),.touch_info(touch_info),
   .report_valid_latched(report_valid_latched),.report_error_latched(report_error_latched),
   .xyz_valid_latched(xyz_valid_latched),.x_latched(x_latched),.y_latched(y_latched),.z_latched(z_latched),
   .touch_valid_latched(touch_valid_latched),.touch_info_latched(touch_info_latched));
 reg [3:0] mode=1;
 reg live_ready=1;
 wire live_valid,record_valid,modulation_valid,record_start,idle,overflow;
 wire [63:0] live_event,record_event,modulation_event;
 input_event_adapter #(.NOTE_CONFIRM(2),.LIVE_Z_PRESS_CONFIRM(1),.LIVE_Z_RELEASE_CONFIRM(1),.LIVE_Z_PRESS_THRESHOLD(16'he000),.LIVE_Z_RELEASE_THRESHOLD(16'hf000),.TIMEOUT_CYCLES(200)) adapter(
   .clk(clk),.rst_n(rst_n),.report_valid(report_valid_latched),.xyz_valid(xyz_valid_latched),
   .report_error(report_error_latched),.x_position(x_latched),.y_position(y_latched),.z_position(z_latched),
   .touch_valid(touch_valid_latched),.touch_info(touch_info_latched),.presence_valid(1'b0),.present(1'b1),
   .mode(mode),.selected_track(2'd0),.loop_tick(7'd0),.start_enter(16'h2000),.start_exit(16'h3000),.flush(1'b0),
   .live_valid(live_valid),.live_ready(live_ready),.live_event(live_event),
   .record_valid(record_valid),.record_ready(1'b1),.record_event(record_event),
   .modulation_valid(modulation_valid),.modulation_ready(1'b1),.modulation_event(modulation_event),
   .record_start(record_start),.record_start_ready(1'b1),.idle(idle),.overflow(overflow));
 integer ons=0,offs=0,i;
 always @(posedge clk) if(rst_n && live_valid && live_ready) begin
   if(live_event[2:0]==0) ons=ons+1;
   if(live_event[2:0]==1 || live_event[2:0]==4) offs=offs+1;
 end
 task frame(input [7:0] sys,input [31:0] touch);
 begin
   @(negedge clk);reader.command_active=0;reader.transaction_active=0;
   for(i=0;i<24;i=i+1)reader.frame[i]=0;
   reader.frame[0]=24;reader.frame[3]=8'h91;
   reader.frame[4]=8'h17;reader.frame[5]=8'h01;reader.frame[7]=sys;
   reader.frame[14]=touch[7:0];reader.frame[15]=touch[15:8];
   reader.frame[16]=touch[23:16];reader.frame[17]=touch[31:24];
   reader.frame[18]=0;reader.frame[19]=8'h80;
   reader.frame[20]=0;reader.frame[21]=8'h80;
   reader.frame[22]=0;reader.frame[23]=8'h80;
   reader.frame_length=24;reader.state=12;
   repeat(12) @(negedge clk);
 end endtask
 initial begin
   repeat(3) @(negedge clk);rst_n=1;
   frame(1,0);frame(1,0);frame(1,0);
   if(ons!=1 || overflow) $fatal(1,"valid airborne F0117 did not start one note");
   frame(1,32'h00100000); // touch age bits alone are not contact or absence
   if(ons!=1 || offs!=0) $fatal(1,"raw touch metadata incorrectly gated airborne note");
   frame(0,0);
   if(offs!=1) $fatal(1,"invalid XYZ report was lost by latch; stale note remains");
   frame(1,0);frame(1,0);frame(1,0);
   if(ons!=2) $fatal(1,"valid reports did not recover after release");
   repeat(220) @(negedge clk);
   if(offs!=2 || overflow) $fatal(1,"sensor silence did not release note");
   $display("tb_input_pipeline PASS");$finish;
 end
 initial begin #100000;$fatal(1,"pipeline timeout");end
endmodule
