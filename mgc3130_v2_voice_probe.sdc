# Probe-only timing constraint: the voice engine is clocked at 100 MHz.
# Full V2 PLL/I2S constraints remain in mgc3130_v2.sdc and Task 12.
create_clock -name clk_sys_100m -period 10.000 [get_ports {clk}]
