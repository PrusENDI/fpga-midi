`timescale 1ns/1ps
module tb_v2_clock_gen;
  logic clk_in = 0;
  logic rst_n = 0;
  wire clk_sys_100m;
  wire pll_locked;
  wire rst_sys_n;
  wire sample_ce;
  wire [31:0] sample_index;
  logic injected_lock = 0;
  wire injected_rst_n;
  integer edges = 0;
  integer release_edges = 0;
  integer release_count = 0;
  realtime last_edge = 0;
  always #10 clk_in = ~clk_in;
  v2_clock_sample_probe dut (.*);
  v2_reset_sync u_injected_lock_check (
    .clk_sys_100m(clk_sys_100m), .rst_n(rst_n),
    .pll_locked(injected_lock), .rst_sys_n(injected_rst_n)
  );
  always @(posedge clk_sys_100m) begin
    if (!rst_n || !pll_locked) release_edges = 0;
    else if (!rst_sys_n) release_edges = release_edges + 1;
    if (pll_locked && rst_n) begin
      if (edges != 0 && (($realtime - last_edge) < 9.99 || ($realtime - last_edge) > 10.01))
        $fatal(1, "PLL period %0f ns, expected 10 ns", $realtime - last_edge);
      edges = edges + 1;
      last_edge = $realtime;
    end
  end
  always @(posedge rst_sys_n) begin
    if (release_edges < 2) $fatal(1, "system reset released before two 100 MHz edges");
    if ($realtime != last_edge) $fatal(1, "system reset release was not aligned to clk_sys_100m");
    release_count = release_count + 1;
  end
  initial begin
    #100 rst_n = 1;
    wait (pll_locked === 1'b1);
    #1000;
    if (edges < 80) $fatal(1, "too few 100 MHz output edges: %0d", edges);
    if (!rst_sys_n || release_count != 1) $fatal(1, "system reset did not synchronously release");
    injected_lock = 1;
    repeat (3) @(posedge clk_sys_100m);
    #1;
    if (injected_rst_n !== 1'b1) $fatal(1, "injected lock did not release reset");
    injected_lock = 0;
    #1;
    if (injected_rst_n !== 1'b0) $fatal(1, "injected unlock did not assert reset asynchronously");
    injected_lock = 1;
    repeat (3) @(posedge clk_sys_100m);
    #1;
    if (injected_rst_n !== 1'b1) $fatal(1, "injected relock did not release reset");
    rst_n = 0;
    #1;
    if (pll_locked !== 1'b0) $fatal(1, "PLL lock did not clear on reset");
    if (rst_sys_n !== 1'b0 || sample_index !== 0)
      $fatal(1, "system reset did not assert asynchronously");
    edges = 0;
    last_edge = 0;
    #100 rst_n = 1;
    wait (pll_locked === 1'b1);
    #1000;
    if (edges < 80) $fatal(1, "PLL failed to relock: edges=%0d", edges);
    if (!rst_sys_n || release_count != 2) $fatal(1, "system reset did not re-release");
    $display("tb_v2_clock_gen PASS lock/reset/relock, 10 ns period, async assert/two-edge release");
    $finish;
  end
  initial begin #200000; $fatal(1, "PLL lock timeout"); end
endmodule
