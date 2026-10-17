`ifdef module_name
`undef module_name
`endif
`ifdef getname
`undef getname
`endif
`define module_name gowin_uart_rx_fifo_core
`define getname(oriName,tmodule_name) \~oriName.tmodule_name
`define En_Reset
`define Reset_Synchronization
`define EBR_BASED
`define FWFT
