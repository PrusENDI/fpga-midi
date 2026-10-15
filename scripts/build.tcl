set root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $root mgc3130_uart.gprj]
set_option -top_module mgc3130_uart_top
set_option -verilog_std v2001
set_option -include_path [file join $root ip gowin_i2c_master]
set_option -use_sspi_as_gpio 1
run all
file mkdir [file join $root bitstream]
file copy -force [file join $root impl pnr ao_0.fs] [file join $root bitstream mgc3130_uart_official_i2c_gao.fs]
puts "Bitstream: [file join $root bitstream mgc3130_uart_official_i2c_gao.fs]"
exit
