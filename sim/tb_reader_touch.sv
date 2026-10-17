`timescale 1ns/1ps
// Parser injection deliberately bypasses the existing I2C register engine;
// production parsing and report/latch timing remain real.
module tb_reader_touch;
 reg clk=0;always #5 clk=~clk;reg rst_n=0;
 tri1 i2c_sda,i2c_scl,mgc_ts;
 wire report_valid,xyz_valid,report_error,touch_valid,busy;
 wire[31:0]touch_info,debug_error_context;wire[15:0]x_position,y_position,z_position,debug_output_mask;
 wire[7:0]gesture_code,debug_message_size;wire[3:0]error_code;
 wire input_valid,xyz_valid_latched,report_valid_latched,report_error_latched,touch_valid_latched;
 wire[15:0]x_latched,y_latched,z_latched;wire[7:0]gesture_latched;wire[31:0]touch_info_latched;
 mgc3130_reader dut(.*);
 mgc3130_input_latch latch(.*);
 task prepare(input[15:0]mask,input[7:0]len,input[7:0]sys);
 integer i;begin
  @(negedge clk);dut.command_active=0;dut.transaction_active=0;
  for(i=0;i<80;i=i+1)dut.frame[i]=0;
  dut.frame[0]=len;dut.frame[3]=8'h91;dut.frame[4]=mask[7:0];dut.frame[5]=mask[15:8];dut.frame[7]=sys;
  dut.frame_length=len;
 end endtask
 task parse;begin dut.state=12;@(posedge clk);#1;end endtask
 task latch_check(input tv,input xyz,input err,input[31:0]touch);
 begin
  if(!report_valid || touch_valid!==tv || xyz_valid!==xyz || report_error!==err || touch_info!==touch)$fatal(1,"reader fields");
  @(posedge clk);#1;
  if(!report_valid_latched || report_error_latched!==err || touch_valid_latched!==tv || touch_info_latched!==touch || input_valid!==(xyz&&!err))$fatal(1,"latch fields");
  @(posedge clk);#1;
  if(report_valid_latched || input_valid || touch_valid_latched)$fatal(1,"valid not pulsed");
 end endtask
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  prepare(16'h0004,12,0);dut.frame[8]=8'h15;dut.frame[9]=8'h42;dut.frame[10]=8'h37;dut.frame[11]=8'h81;
  parse();latch_check(1,0,0,32'h81374215);
  prepare(16'h001f,26,1);dut.frame[10]=8'h08;
  dut.frame[14]=8'h02;dut.frame[15]=8'h04;dut.frame[16]=8'h06;dut.frame[17]=8'h08;
  dut.frame[20]=8'h34;dut.frame[21]=8'h12;dut.frame[22]=8'h78;dut.frame[23]=8'h56;dut.frame[24]=8'hbc;dut.frame[25]=8'h9a;
  parse();if(x_position!==16'h1234||y_position!==16'h5678||z_position!==16'h9abc||gesture_code!==8'h08)$fatal(1,"dynamic offsets");
  latch_check(1,1,0,32'h08060402);
  prepare(16'h0010,14,0);parse();latch_check(0,0,0,0);
  prepare(16'h0006,16,0);dut.frame[12]=8'h10;parse();latch_check(1,0,0,32'h10);
  prepare(16'h0005,14,0);dut.frame[10]=8'h08;parse();latch_check(1,0,0,32'h08);
  prepare(16'h0004,11,0);parse();latch_check(0,0,1,0);
  prepare(16'h0044,12,0);parse();latch_check(0,0,1,0);
  prepare(16'h0204,12,0);parse();latch_check(0,0,1,0);
  prepare(16'h0004,7,0);parse();latch_check(0,0,1,0);
  prepare(16'h0004,12,0);dut.frame[8]=1;parse();latch_check(1,0,0,1);
  @(negedge clk);dut.state=14;@(posedge clk);#1;latch_check(0,0,1,0);
  prepare(16'h0004,12,0);dut.frame[8]=2;parse();latch_check(1,0,0,2);
  @(negedge clk);dut.state=17;@(posedge clk);#1;latch_check(0,0,1,0);
  $display("tb_reader_touch PASS");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule
module Gowin_I2C_Master(input I_CLK,I_RESETN,I_TX_EN,input[2:0]I_WADDR,input[7:0]I_WDATA,input I_RX_EN,input[2:0]I_RADDR,output[7:0]O_RDATA,output O_IIC_INT,inout SDA,SCL);
 assign O_RDATA=0;assign O_IIC_INT=0;
endmodule
