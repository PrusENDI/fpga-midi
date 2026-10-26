// V2 clock boundary: 50 MHz board oscillator to a single 100 MHz system clock.
// Simulation uses V2_SIM to bypass the device PLL and keep testbenches portable.
module v2_clock_gen (
  input  logic clk_in,
  input  logic rst_n,
  output logic clk_sys_100m,
  output logic pll_locked
);
`ifdef V2_SIM
  assign clk_sys_100m = clk_in;
  assign pll_locked   = rst_n;
`else
  wire clk_pll;
  wire pll_lock_i;
  PLL #(
    .FCLKIN("50.0"),
    .IDIV_SEL(1),
    .FBDIV_SEL(8),
    .ODIV0_SEL(4),
    .CLKOUT0_EN("TRUE"),
    .CLKOUT1_EN("FALSE"),
    .CLKOUT2_EN("FALSE"),
    .CLKOUT3_EN("FALSE"),
    .CLKOUT4_EN("FALSE"),
    .CLKOUT5_EN("FALSE"),
    .CLKOUT6_EN("FALSE"),
    .CLKFB_SEL("INTERNAL")
  ) u_pll (
    .CLKOUT0(clk_pll), .CLKOUT1(), .CLKOUT2(), .CLKOUT3(),
    .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUT(),
    .LOCK(pll_lock_i), .CLKIN(clk_in), .CLKFB(1'b0),
    .ENCLK0(1'b1), .ENCLK1(1'b0), .ENCLK2(1'b0), .ENCLK3(1'b0),
    .ENCLK4(1'b0), .ENCLK5(1'b0), .ENCLK6(1'b0),
    .FBDSEL(6'd0), .IDSEL(6'd0), .MDSEL(7'd0), .MDSEL_FRAC(3'd0),
    .ODSEL0(7'd0), .ODSEL0_FRAC(3'd0), .ODSEL1(7'd0), .ODSEL2(7'd0),
    .ODSEL3(7'd0), .ODSEL4(7'd0), .ODSEL5(7'd0), .ODSEL6(7'd0),
    .DT0(4'd0), .DT1(4'd0), .DT2(4'd0), .DT3(4'd0),
    .PSSEL(3'd0), .PSDIR(1'b0), .PSPULSE(1'b0), .SSCPOL(1'b0),
    .SSCON(1'b0), .SSCMDSEL(7'd0), .SSCMDSEL_FRAC(3'd0),
    .ICPSEL(6'd0), .LPFRES(3'd0), .LPFCAP(2'd0),
    .RESET(~rst_n), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0)
  );
  assign clk_sys_100m = clk_pll;
  assign pll_locked   = pll_lock_i;
`endif
endmodule
