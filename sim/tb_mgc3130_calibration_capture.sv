`timescale 1ns/1ps
module tb_mgc3130_calibration_capture;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, mgc_ready=0, report_valid=0, xyz_valid=0, report_error=0, touch_valid=0, reader_busy=0;
  reg [31:0] touch_info=0; reg [15:0] x_position=0,y_position=0,z_position=0;
  reg [7:0] gesture_code=0; reg [3:0] error_code=0; reg tx_ready=1;
  wire tx_valid; wire [7:0] tx_data; wire capture_overflow; wire [15:0] report_sequence;
  mgc3130_calibration_capture #(.DEPTH(2),.BUILD_TAG(32'h424C3031)) dut(.*);
  reg [7:0] bytes[0:127]; integer count=0, i;
  always @(posedge clk) if(tx_valid && tx_ready) begin bytes[count]=tx_data; count=count+1; end
  task report(input [15:0] x,input [15:0] y,input [15:0] z); begin
    @(negedge clk); x_position=x; y_position=y; z_position=z; xyz_valid=1; report_valid=1;
    @(negedge clk); report_valid=0; xyz_valid=0;
  end endtask
  function automatic [7:0] crc8(input integer start); integer j,k; reg [7:0] c; begin
    c=0; for(j=start;j<start+29;j=j+1) begin c=c^bytes[j]; for(k=0;k<8;k=k+1)c=c[7]?((c<<1)^8'h07):(c<<1); end crc8=c;
  end endfunction
  initial begin
    repeat(2) @(negedge clk); rst_n=1; mgc_ready=1;
    repeat(40) @(posedge clk);
    if(count<32) $fatal(1,"metadata frame missing count=%0d",count);
    if(bytes[0]!==8'hA5 || bytes[1]!==8'h5A || bytes[2]!==1 || bytes[3]!==0 || bytes[4]!==32)
      $fatal(1,"metadata header mismatch");
    if(bytes[31]!==crc8(2)) $fatal(1,"metadata CRC mismatch");
    report(16'h1234,16'h5678,16'h9abc); repeat(40) @(posedge clk);
    if(report_sequence!==1 || count<64) $fatal(1,"report frame missing seq=%0d count=%0d",report_sequence,count);
    if(bytes[32]!==8'hA5 || bytes[35]!==1 || {bytes[45],bytes[44]}!==16'h1234 ||
       {bytes[47],bytes[46]}!==16'h5678 || {bytes[49],bytes[48]}!==16'h9abc)
      $fatal(1,"report payload mismatch");
    if(bytes[63]!==crc8(34)) $fatal(1,"report CRC mismatch");
    tx_ready=0;
    repeat(6) begin
      @(negedge clk); report_valid=1; xyz_valid=1;
      @(negedge clk); report_valid=0; xyz_valid=0;
    end
    repeat(4) @(posedge clk);
    $display("overflow=%0d fifo_count=%0d seq=%0d frame_active=%0d", capture_overflow, dut.fifo_count, report_sequence, dut.frame_active);
    if(!capture_overflow) $fatal(1,"overflow was not sticky");
    $display("tb_mgc3130_calibration_capture PASS"); $finish;
  end
  initial begin #100000; $fatal(1,"timeout"); end
endmodule
