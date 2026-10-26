# Board oscillator is 50 MHz. The PLL output is the only V2 system clock.
create_clock -name clk_50m -period 20.000 [get_ports {clk_in}]
create_generated_clock -name clk_sys_100m -source [get_ports {clk_in}] \
    -multiply_by 2 [get_ports {clk_sys_100m}]

# PCM5102A I2S uses a 768 kHz BCLK (48 kHz x 16-bit stereo).
# Keep this as a virtual interface clock for the V2 top-level integration.
create_clock -name i2s_bclk -period 1.302083 -waveform {0.000 0.651042}
set_clock_groups -asynchronous -group [get_clocks {clk_sys_100m}] \
    -group [get_clocks {i2s_bclk}]
