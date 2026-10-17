`timescale 1ns/1ps
module tb_mode_gated_event_paths;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, flush=0;
    reg live_in_valid=0; reg [63:0] live_in_data=0; wire live_in_ready;
    wire live_out_valid; reg live_out_ready=0; wire [63:0] live_out_data;
    reg record_in_valid=0; reg [63:0] record_in_data=0; wire record_in_ready;
    wire record_out_valid; reg record_out_ready=0; wire [63:0] record_out_data;
    reg modulation_in_valid=0; reg [63:0] modulation_in_data=0; wire modulation_in_ready;
    wire modulation_out_valid; reg modulation_out_ready=0; wire [63:0] modulation_out_data;
    wire [15:0] live_level,record_level; wire modulation_pending;

    performance_event_ingress #(.DEPTH(4)) dut(.*);

    task push_live(input [63:0] value);
      begin
        @(negedge clk); live_in_data=value; live_in_valid=1;
        do @(posedge clk); while(!live_in_ready);
        @(negedge clk); live_in_valid=0;
      end
    endtask
    task push_record(input [63:0] value);
      begin
        @(negedge clk); record_in_data=value; record_in_valid=1;
        do @(posedge clk); while(!record_in_ready);
        @(negedge clk); record_in_valid=0;
      end
    endtask
    initial begin
      repeat(3) @(negedge clk); rst_n=1;
      push_live(64'h11); push_record(64'h22);
      if(!record_out_valid || record_out_data!==64'h22)
        $fatal(1,"record path was blocked by stalled live output");
      repeat(3) push_live(64'h33);
      if(record_in_ready!==1'b1) $fatal(1,"record ready coupled to live queue");
      $display("tb_mode_gated_event_paths PASS"); $finish;
    end
    initial begin #10000; $fatal(1,"timeout"); end
endmodule
