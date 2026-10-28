`timescale 1ns/1ps
module tb_v2_voice_trace;
  logic clk=0,rst_n=0,sample_ce=0,event_valid=0; logic [95:0] event_data=0;
  logic event_ready; logic signed [15:0] mixed_sample; logic sample_valid,voice_overflow;
  logic [31:0] active_bitmap; logic [7:0] revoice_count; logic [5:0] active_voice_count;
  integer i,w;
  always #5 clk=~clk;
  v2_voice_engine_mux dut(.*);
  task automatic send(input [3:0] typ,input [7:0] n);
    begin @(negedge clk); event_data=0; event_data[94:91]=typ; event_data[71:64]=n; event_data[63:56]=255; event_valid=1;
      w=0; while(!event_ready) begin @(negedge clk); w=w+1; if(w>200)$fatal(1,"send timeout t=%0d n=%0d scan=%b rd=%b calc=%b",typ,n,dut.scan_active,dut.rd_valid,dut.calc_valid); end
      $display("ready t=%0d n=%0d time=%0t scan=%b rd=%b calc=%b final=%b",typ,n,$time,dut.scan_active,dut.rd_valid,dut.calc_valid,dut.engine_final);
      @(posedge clk); #1 event_valid=0;
    end
  endtask
  task automatic sample_once;
    begin @(negedge clk); sample_ce=1; @(posedge clk); #1 sample_ce=0; w=0;
      while(!sample_valid) begin @(posedge clk); w=w+1; if(w>100)$fatal(1,"sample timeout time=%0t scan=%b rd=%b calc=%b",$time,dut.scan_active,dut.rd_valid,dut.calc_valid); end
      $display("sample time=%0t mix=%0d active=%h",$time,mixed_sample,active_bitmap); #1;
    end
  endtask
  initial begin
    repeat(2)@(posedge clk); rst_n=1; @(negedge clk);
    for(i=0;i<32;i=i+1) send(1,60);
    $display("allocated active=%0d",active_voice_count);
    send(1,100);
    $display("overflow active=%0d ov=%b",active_voice_count,voice_overflow);
    @(negedge clk); sample_ce=1; @(posedge clk); #1 sample_ce=0;
    @(negedge clk); event_data=0;event_data[94:91]=2;event_data[71:64]=60;event_valid=1;w=0;
    while(!event_ready) begin @(negedge clk);w=w+1; if(w>200)$fatal(1,"busy ready timeout scan=%b rd=%b calc=%b",dut.scan_active,dut.rd_valid,dut.calc_valid); end
    $display("busy ready time=%0t sv=%b scan=%b rd=%b calc=%b final=%b",$time,sample_valid,dut.scan_active,dut.rd_valid,dut.calc_valid,dut.engine_final);
    @(posedge clk); #1 event_valid=0; $display("busy handshake time=%0t sv=%b active=%h",$time,sample_valid,active_bitmap);
    while(!sample_valid) begin @(posedge clk);w=w+1;if(w>300)$fatal(1,"missed sample");end
    $display("done busy"); $finish;
  end
endmodule
