set root [file normalize [file join [file dirname [info script]] ..]]
set project [file join $root calibration mgc3130_uart_calibration.gprj]
open_project $project
set_option -top_module mgc3130_uart_calibration_top
set_option -verilog_std sysv2017
set_option -include_path [file join $root ip gowin_i2c_master]
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
run syn
run pnr
set output_dir [file join $root calibration bitstream]
file mkdir $output_dir
file copy -force [file join $root calibration impl pnr mgc3130_uart_calibration.fs] [file join $output_dir mgc3130_uart_calibration.fs]
puts "Bitstream: [file join $output_dir mgc3130_uart_calibration.fs]"
exit
