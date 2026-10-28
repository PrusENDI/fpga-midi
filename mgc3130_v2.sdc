create_clock -name clk_50m -period 20.000 [get_ports {clk_50m}]
set_false_path -from [get_ports {uart_rx}]
