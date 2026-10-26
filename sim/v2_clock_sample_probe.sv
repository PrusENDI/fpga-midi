// Synthesis-only probe keeps both PLL and scheduler observable.
module v2_clock_sample_probe (
  input logic clk_in,
  input logic rst_n,
  output logic clk_sys_100m,
  output logic pll_locked,
  output logic sample_ce,
  output logic [31:0] sample_index
);
  v2_clock_gen u_clock (.*);
  v2_sample_scheduler u_scheduler (
    .clk_sys(clk_sys_100m),
    .rst_n(rst_n & pll_locked),
    .sample_ce(sample_ce),
    .sample_index(sample_index)
  );
endmodule
