`timescale 1ns/1ps
module tb_mgc3130_uart_calibration_top;
  reg clk=0; always #10 clk=~clk;
  GSR GSR(.GSRI(1'b1));
  tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
  pullup(mgc_sda); pullup(mgc_scl); pullup(mgc_ts); pullup(mgc_mclr);
  reg uart_rx=1; wire uart_tx,bck,lrck,din;
  mgc3130_uart_calibration_top #(.RESET_LOW_MS(1),.STARTUP_WAIT_MS(1)) dut(
    .clk_50m(clk),.mgc_sda(mgc_sda),.mgc_scl(mgc_scl),.mgc_ts(mgc_ts),.mgc_mclr(mgc_mclr),
    .uart_tx(uart_tx),.uart_rx(uart_rx),.pcm5102a_bck(bck),.pcm5102a_lrck(lrck),.pcm5102a_din(din));
  localparam integer BIT_CLKS=434;
  task automatic receive_byte(output [7:0] value);
    integer k; begin
      wait(uart_tx===1'b0); repeat(BIT_CLKS/2) @(posedge clk);
      for(k=0;k<8;k=k+1) begin repeat(BIT_CLKS) @(posedge clk); value[k]=uart_tx; end
      repeat(BIT_CLKS) @(posedge clk);
    end
  endtask
  reg [7:0] frame[0:31]; integer i;
  initial begin
    wait(dut.mgc_ready===1'b1);
    wait(dut.capture_valid===1'b1);
    for(i=0;i<32;i=i+1) receive_byte(frame[i]);
    if(frame[0]!==8'hA5 || frame[1]!==8'h5A || frame[2]!==1 || frame[3]!==0 || frame[4]!==32)
      $fatal(1,"calibration startup frame missing");
    if(frame[24]!==8'h31 || frame[25]!==8'h4C || frame[26]!==8'h41 || frame[27]!==8'h43)
      $fatal(1,"build tag missing");
    $display("tb_mgc3130_uart_calibration_top PASS"); $finish;
  end
  initial begin #150_000_000; $fatal(1,"timeout"); end
endmodule
