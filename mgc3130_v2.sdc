# Board oscillator is 50 MHz. The PLL output is the only V2 system clock.
create_clock -name clk_50m -period 20.000 [get_ports {clk_in}]
create_generated_clock -name clk_sys_100m -source [get_ports {clk_in}] -multiply_by 2 [get_ports {clk_sys_100m}]

# I2S BCLK is a synchronous output derived with clock enables in clk_sys_100m.
# Do not cut paths or add an asynchronous clock group for that output.
