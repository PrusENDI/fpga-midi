`timescale 1ns/1ps
module tb_live_fifo_burst;
 import performance_event_pkg::*;
 reg clk=0; always #5 clk=~clk; reg rst_n=0,flush=0;
 reg in_valid=0; wire in_ready; reg [63:0] in_data=0; wire out_valid; reg out_ready=0; wire [63:0] out_data; wire [15:0] live_level,record_level; wire mod_pending;
 wire live_in_ready,live_out_valid; wire [63:0] live_out_data; wire live_out_ready;
 wire record_in_ready,record_out_valid; wire [63:0] record_out_data; reg record_in_valid=0,record_out_ready=0; reg [63:0] record_in_data=0;
 reg modulation_in_valid=0,modulation_out_ready=0; wire modulation_in_ready,modulation_out_valid; reg [63:0] modulation_in_data=0; wire [63:0] modulation_out_data;
 assign live_in_valid=in_valid; assign live_in_data=in_data; assign in_ready=live_in_ready; assign out_valid=live_out_valid; assign out_data=live_out_data; assign live_out_ready=out_ready;
 performance_event_ingress #(.DEPTH(16)) dut(.clk(clk),.rst_n(rst_n),.flush(flush),.live_in_valid(in_valid),.live_in_ready(live_in_ready),.live_in_data(in_data),.live_out_valid(live_out_valid),.live_out_ready(out_ready),.live_out_data(live_out_data),.record_in_valid(record_in_valid),.record_in_ready(record_in_ready),.record_in_data(record_in_data),.record_out_valid(record_out_valid),.record_out_ready(record_out_ready),.record_out_data(record_out_data),.modulation_in_valid(modulation_in_valid),.modulation_in_ready(modulation_in_ready),.modulation_in_data(modulation_in_data),.modulation_out_valid(modulation_out_valid),.modulation_out_ready(modulation_out_ready),.modulation_out_data(modulation_out_data),.live_level(live_level),.record_level(record_level),.modulation_pending(mod_pending));
 integer i; integer accepted=0;
 initial begin
   repeat(2)@(posedge clk); rst_n=1;
   for(i=0;i<8;i=i+1) begin
     @(negedge clk); in_data=64'd0; in_data[2:0]=EVENT_NOTE_REVOICE; in_data[25:19]=48+i; in_valid=1;
     @(posedge clk); while(!in_ready) @(posedge clk); accepted=accepted+1; @(negedge clk); in_valid=0;
   end
   if(live_level!=8) $fatal(1,"LIVE burst level %0d expected 8",live_level);
   if(record_level!=0) $fatal(1,"record queue coupled to LIVE burst");
   out_ready=1; repeat(12)@(posedge clk);
   if(live_level!=0) $fatal(1,"LIVE burst did not drain");
   $display("tb_live_fifo_burst PASS"); $finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
