`timescale 1ns/1ps
module tb_loop_audio_path;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,rx_valid=0,tx_ready=1,record_start=0,live_valid=0,record_valid=0;
 reg[7:0]rx_data=0;wire rx_ready,tx_valid;wire[7:0]tx_data;reg[63:0]live_data=0,record_data=0;wire live_ready,record_ready;
 reg modulation_valid=0; reg[63:0] modulation_data=0; wire modulation_ready; wire[1:0] selected_track; wire[15:0] start_enter,start_exit;
 reg [15:0] report_count=0,xyz_count=0; reg adapter_overflow=0;
 wire signed[15:0]mixed_sample;wire sample_valid;wire[2:0]active_voice_count;wire[3:0]mode;wire[6:0]loop_tick;wire active_valid,fault_latched,flush_events;wire [2:0] router_debug;
 loop_audio_path #(.CLK_HZ(12000),.OP_TIMEOUT_CYCLES(4000),.BOUNDARY_TIMEOUT_CYCLES(400000),.RX_TIMEOUT_CYCLES(100)) dut(.*,.adapter_idle(1'b1));
 task byte_in(input[7:0]b);begin @(negedge clk);rx_data=b;rx_valid=1;while(!rx_ready)@(negedge clk);@(negedge clk);rx_valid=0;end endtask
 task cmd(input[7:0]op,input[7:0]a0,input[7:0]seq);reg[7:0]c;begin c=op^8'd4^a0^seq;byte_in(8'h55);byte_in(8'haa);byte_in(op);byte_in(4);byte_in(a0);byte_in(0);byte_in(0);byte_in(0);byte_in(seq);byte_in(c);end endtask
 initial begin repeat(3)@(negedge clk);rst_n=1;cmd(4,0,1);repeat(100)@(negedge clk);if(mode!=0||active_valid)$fatal(1,"empty PLAY accepted");cmd(1,1,2);repeat(100)@(negedge clk);if(mode!=1)$fatal(1,"LIVE command");
  @(negedge clk);live_data[2:0]=0;live_data[25:19]=60;live_data[33:26]=90;live_valid=1;while(!live_ready)@(negedge clk);@(negedge clk);live_valid=0;repeat(20)@(negedge clk);if(active_voice_count==0)$fatal(1,"live event did not reach mixer");
  // A pending modulation point must not deadlock a simultaneous control event.
  modulation_data[2:0]=4; modulation_valid=1;
  force dut.control.ingress.modulation_out_ready=1'b0;
  force dut.control.ingress.modulation_in_valid=1'b1;
  force dut.control.ingress.modulation_in_data=64'h1234;
  @(posedge clk); #1 if(!dut.control.ingress.modulation_pending)$fatal(1,"modulation was not routed through ingress");
  release dut.control.ingress.modulation_out_ready;
  release dut.control.ingress.modulation_in_valid;
  release dut.control.ingress.modulation_in_data;
  force dut.out_valid=1'b1;
  #1 if(!dut.out_ready)$fatal(1,"control ready blocked by modulation");
  release dut.out_valid;
  modulation_valid=0;
  cmd(5,0,3);repeat(100)@(negedge clk);if(active_voice_count!=0)$fatal(1,"STOP did not release mixer");$display("tb_loop_audio_path PASS");$finish;end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
