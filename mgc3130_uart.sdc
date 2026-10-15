create_clock -name clk_50m -period 20.000 [get_ports {clk_50m}]

# GAO adds the JTAG TCK port during synthesis. USB-JTAG TCK and the board
# oscillator are independent clocks; their edges have no fixed relationship.
# Retain timing analysis within both domains, exclude only crossings.
create_clock -name gao_tck -period 50.000 [get_ports {tck_pad_i}]
set_clock_groups -asynchronous -group [get_clocks {clk_50m}] -group [get_clocks {gao_tck}]
