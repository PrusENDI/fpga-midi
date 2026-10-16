`timescale 1ns/1ps
module tb_command_mailbox;
 import control_protocol_pkg::*;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,rx_valid=0,tx_ready=1,csr_ready=1,csr_rsp_valid=0;
 reg [7:0] rx_data=0,csr_rsp_status=ACK_APPLIED;
 reg [31:0] csr_rsp_rdata=0;
 wire rx_ready,tx_valid,csr_valid,csr_write,csr_rsp_ready,urgent_stop;
 wire [7:0] tx_data,csr_addr; wire [31:0] csr_wdata;
 command_mailbox #(.RX_TIMEOUT_CYCLES(20)) dut(.*);
 reg [7:0] received[0:1023]; integer n=0,requests=0;
 reg [7:0] last_addr; reg [31:0] last_data; reg last_write;
 always @(posedge clk) begin
  if(tx_valid && tx_ready) begin received[n]=tx_data; n=n+1; end
  if(csr_valid && csr_ready) begin requests=requests+1; last_addr=csr_addr;last_data=csr_wdata;last_write=csr_write;end
 end
 task byte_in(input [7:0] b); begin
  @(negedge clk);rx_data=b;rx_valid=1;
  do @(posedge clk); while(!rx_ready);
  @(negedge clk);rx_valid=0;
 end endtask
 task packet(input [7:0] op,input [31:0] args,input [7:0] seq,input [7:0] len,input bad);
 reg [7:0] sum; begin
  sum=op^len^args[7:0]^args[15:8]^args[23:16]^args[31:24]^seq;
  byte_in('h55);byte_in('haa);byte_in(op);byte_in(len);byte_in(args[7:0]);
  repeat(3) @(negedge clk);
  byte_in(args[15:8]);byte_in(args[23:16]);byte_in(args[31:24]);byte_in(seq);byte_in(sum^bad);
 end endtask
 task response(input [7:0] status,input [31:0] data); begin
  @(negedge clk);csr_rsp_status=status;csr_rsp_rdata=data;csr_rsp_valid=1;
  do @(posedge clk); while(!csr_rsp_ready);
  @(negedge clk);csr_rsp_valid=0;
 end endtask
 task expect_reply(input integer index,input [7:0] op,input [7:0] status,input [31:0] data,input [7:0] seq);
 integer base,j; reg [7:0] sum; begin
  base=index*10; wait(n>=base+10);sum=0;
  for(j=2;j<9;j=j+1)sum=sum^received[base+j];
  if(received[base]!==8'haa || received[base+1]!==8'h55 || received[base+2]!==op || received[base+3]!==status ||
   {received[base+7],received[base+6],received[base+5],received[base+4]}!==data || received[base+8]!==seq || received[base+9]!==sum)
   $fatal(1,"reply %0d mismatch status=%0d",index,received[base+3]);
 end endtask
 integer before_count;reg [7:0] held;
 initial begin
  repeat(3)@(negedge clk);rst_n=1;
  packet(CMD_SET_BPM,32'h12340078,8'h31,4,0);
  wait(requests==1);if(last_addr!==CSR_BPM || last_data!==32'h12340078 || !last_write)$fatal(1,"CSR mapping");
  expect_reply(0,CMD_SET_BPM,ACK_ACCEPTED,0,8'h31);
  packet(CMD_PLAY,0,8'h32,4,0);
  expect_reply(1,CMD_PLAY,ACK_BUSY,0,8'h32);
  response(ACK_APPLIED,32'h87654321);expect_reply(2,CMD_SET_BPM,ACK_APPLIED,32'h87654321,8'h31);
  packet(CMD_STOP,0,1,4,1);expect_reply(3,CMD_STOP,ACK_ERROR,0,1);if(urgent_stop)$fatal(1,"corrupt STOP urgent");
  packet(CMD_PLAY,0,2,3,0);expect_reply(4,CMD_PLAY,ACK_ERROR,0,2);
  packet(8'hfe,0,3,4,0);expect_reply(5,8'hfe,ACK_REJECTED,0,3);
  packet(CMD_READ_CSR,32'h00000100,4,4,0);expect_reply(6,CMD_READ_CSR,ACK_REJECTED,0,4);
  if(requests!=1)$fatal(1,"invalid packet side effect");
  byte_in('h55);byte_in('h12);byte_in('h55);byte_in('haa);byte_in(CMD_PLAY);
  repeat(25)@(negedge clk);
  byte_in('h55); // overlapping first header byte must resynchronize
  packet(CMD_READ_CSR,32'h34,5,4,0);wait(requests==2);
  if(last_addr!==8'h34 || last_write)$fatal(1,"READ_CSR mapping");
  response(ACK_APPLIED,32'h11223344);expect_reply(7,CMD_READ_CSR,ACK_ACCEPTED,0,5);expect_reply(8,CMD_READ_CSR,ACK_APPLIED,32'h11223344,5);
  // Urgent priority must bypass blocked TX and an outstanding CSR response.
  tx_ready=0;packet(CMD_COMMIT,0,6,4,0);wait(requests==3);wait(tx_valid);held=tx_data;
  packet(CMD_STOP,0,7,4,0);repeat(3)@(negedge clk);
  if(!urgent_stop || requests!=3 || !tx_valid || tx_data!==held)$fatal(1,"urgent STOP/stalled TX");
  response(ACK_ERROR,0);wait(requests==4);repeat(2)@(negedge clk);
  if(last_addr!==CSR_STOP || urgent_stop)$fatal(1,"STOP dispatch");
  response(ACK_APPLIED,0);tx_ready=1;
  expect_reply(9,CMD_COMMIT,ACK_ACCEPTED,0,6);expect_reply(10,CMD_COMMIT,ACK_ERROR,0,6);
  expect_reply(11,CMD_STOP,ACK_ACCEPTED,0,7);expect_reply(12,CMD_STOP,ACK_APPLIED,0,7);
  tx_ready=0;packet(CMD_RECORD,0,8,4,0);wait(requests==5);
  packet(CMD_RESET,0,9,4,0);if(!urgent_stop)$fatal(1,"urgent RESET");
  response(ACK_ERROR,0);wait(requests==6);response(ACK_APPLIED,0);tx_ready=1;
  expect_reply(13,CMD_RECORD,ACK_ACCEPTED,0,8);expect_reply(14,CMD_RECORD,ACK_ERROR,0,8);
  expect_reply(15,CMD_RESET,ACK_ACCEPTED,0,9);expect_reply(16,CMD_RESET,ACK_APPLIED,0,9);
  // Fill reply storage, then complete an ordinary busy frame. It must remain
  // BUSY even when the older CSR completes before its reply can be queued.
  tx_ready=0;packet(CMD_STATUS,0,10,4,0);wait(requests==7);
  packet(CMD_PLAY,0,11,4,1);packet(CMD_PLAY,0,12,4,1);packet(CMD_PLAY,0,13,4,1);
  packet(CMD_PLAY,0,14,4,0);repeat(2)@(negedge clk);
  if(rx_ready || csr_rsp_ready)$fatal(1,"full queues must backpressure");
  csr_rsp_valid=1;csr_rsp_status=ACK_APPLIED;csr_rsp_rdata=32'habcdef01;
  repeat(5)@(negedge clk);
  if(csr_rsp_ready || requests!=7)$fatal(1,"terminal lost under backpressure");
  tx_ready=1;do @(posedge clk);while(!csr_rsp_ready);
  @(negedge clk);csr_rsp_valid=0;
  expect_reply(17,CMD_STATUS,ACK_ACCEPTED,0,10);
  expect_reply(18,CMD_PLAY,ACK_ERROR,0,11);expect_reply(19,CMD_PLAY,ACK_ERROR,0,12);
  expect_reply(20,CMD_PLAY,ACK_ERROR,0,13);expect_reply(21,CMD_STATUS,ACK_APPLIED,32'habcdef01,10);
  expect_reply(22,CMD_PLAY,ACK_BUSY,0,14);
  repeat(5)@(negedge clk);if(requests!=7)$fatal(1,"buffered BUSY executed later");
  // CSR request and payload remain stable while the manager refuses them.
  csr_ready=0;packet(CMD_SET_THRESHOLDS,32'h12345678,15,4,0);wait(csr_valid);
  repeat(8)begin @(negedge clk);if(!csr_valid || csr_addr!==CSR_THRESHOLDS || csr_wdata!==32'h12345678 || !csr_write)$fatal(1,"CSR request unstable");end
  csr_ready=1;wait(requests==8);response(ACK_REJECTED,32'h42);
  expect_reply(23,CMD_SET_THRESHOLDS,ACK_ACCEPTED,0,15);expect_reply(24,CMD_SET_THRESHOLDS,ACK_REJECTED,32'h42,15);
  // Invalid priority arguments must never cancel an outstanding operation.
  packet(CMD_COMMIT,0,16,4,0);wait(requests==9);
  expect_reply(25,CMD_COMMIT,ACK_ACCEPTED,0,16);
  packet(CMD_STOP,32'h00000001,17,4,0);
  if(urgent_stop)$fatal(1,"invalid STOP asserted urgent");
  expect_reply(26,CMD_STOP,ACK_REJECTED,0,17);
  if(urgent_stop || requests!=9)$fatal(1,"invalid STOP side effect");
  packet(CMD_RESET,32'h00010000,18,4,0);
  if(urgent_stop)$fatal(1,"invalid RESET asserted urgent");
  expect_reply(27,CMD_RESET,ACK_REJECTED,0,18);
  if(urgent_stop || requests!=9)$fatal(1,"invalid RESET side effect");
  response(ACK_APPLIED,0);expect_reply(28,CMD_COMMIT,ACK_APPLIED,0,16);
  $display("tb_command_mailbox PASS");$finish;
 end
 initial begin #200000;$fatal(1,"timeout n=%0d requests=%0d",n,requests);end
endmodule
