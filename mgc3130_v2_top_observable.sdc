# V2 board input is 50 MHz.  The internal GW5A PLL generates the only
# free-running system clock at 100 MHz; the PLL model/implementation exposes
# the generated clock automatically as u_v2/u_clock/u_pll/CLKOUT0.
create_clock -name clk_50m -period 20.000 [get_ports {clk_50m}]
set_false_path -from [get_ports {uart_rx}]
