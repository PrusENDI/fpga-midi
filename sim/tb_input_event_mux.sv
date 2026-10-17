`timescale 1ns/1ps
module tb_input_event_mux;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,flush=0;
 reg live_valid=0,record_valid=0,out_ready=1;reg [63:0] live_data=64'h11,record_data=64'h22;
 wire live_ready,record_ready,out_valid;wire [63:0] out_data;wire pending_debug;
 input_event_mux dut(.*);
 initial begin
  repeat(2)@(posedge clk);rst_n=1;
  live_valid=1;@(posedge clk);#1;if(!out_valid||out_data!==64'h11||!live_ready)$fatal(1,"live mux");
  record_valid=1;live_data=64'h33;@(posedge clk);#1;if(out_data[61]!==1'b1||out_data[5:0]!==6'h22)$fatal(1,"record priority/flag");
  out_ready=0;@(posedge clk);#1;if(!out_valid||out_data[61]!==1'b1||out_data[5:0]!==6'h22)$fatal(1,"held record");
  record_valid=0;live_valid=0;out_ready=1;@(posedge clk);#1;if(out_valid)$fatal(1,"stale mux event");
  flush=1;@(posedge clk);flush=0;record_valid=1;@(posedge clk);#1;if(!out_valid)$fatal(1,"post flush");
  $display("tb_input_event_mux PASS");$finish;
 end
 initial begin #1000;$fatal(1,"timeout");end
endmodule
