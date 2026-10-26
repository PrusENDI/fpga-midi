`timescale 1ns/1ps
module tb_v2_clock_gen;
  logic clk_in = 0;
  logic rst_n = 0;
  wire clk_sys_100m;
  wire pll_locked;
  integer edges = 0;
  realtime last_edge = 0;
  always #10 clk_in = ~clk_in;
  v2_clock_gen dut (.*);
  always @(posedge clk_sys_100m) begin
    if (pll_locked && rst_n) begin
      if (edges != 0 && (($realtime - last_edge) < 9.99 || ($realtime - last_edge) > 10.01))
        $fatal(1, "PLL period %0f ns, expected 10 ns", $realtime - last_edge);
      edges = edges + 1;
      last_edge = $realtime;
    end
  end
  initial begin
    #100 rst_n = 1;
    wait (pll_locked === 1'b1);
    #1000;
    if (edges < 80) $fatal(1, "too few 100 MHz output edges: %0d", edges);
    rst_n = 0;
    #10;
    if (pll_locked !== 1'b0) $fatal(1, "PLL lock did not clear on reset");
    edges = 0;
    last_edge = 0;
    #100 rst_n = 1;
    wait (pll_locked === 1'b1);
    #1000;
    if (edges < 80) $fatal(1, "PLL failed to relock: edges=%0d", edges);
    $display("tb_v2_clock_gen PASS lock/reset/relock and 10 ns period");
    $finish;
  end
  initial begin #200000; $fatal(1, "PLL lock timeout"); end
endmodule
