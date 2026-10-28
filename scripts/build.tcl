set root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root mgc3130_uart.gprj]
# The wrapper fixes LOOP_CONTROL_ENABLE=1 so GUI and batch builds cannot
# accidentally produce the legacy ASCII top.
set_option -top_module mgc3130_uart_loop_top
set_option -verilog_std sysv2017
set_option -include_path [file join $root ip gowin_i2c_master]
set_option -include_path [file join $root ip gowin_uart_rx_fifo]
# E2 is a dual-purpose CPU/SSPI pin on GW5A.  The board oscillator uses it
# as a regular clock input, so both dedicated-function overrides are required.
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
run all
file mkdir [file join $root bitstream]
file copy -force [file join $root impl pnr ao_0.fs] [file join $root bitstream mgc3130_uart_loop.fs]
puts "Bitstream: [file join $root bitstream mgc3130_uart_loop.fs]"
exit
