// Physical 8N1 RX boundary. The output is a byte-level stream for
// loop_control_plane; TX serialization remains a separate task.
module uart_control_link #(
 parameter integer CLK_HZ=50_000_000,parameter integer BAUD=115_200,
 parameter integer FIFO_DEPTH=16,parameter integer RX_TIMEOUT_CYCLES=500000
)(
 input wire clk,rst,input wire rx,
 output wire rx_valid,input wire rx_ready,output wire [7:0] rx_data,
 output wire overflow,output wire framing_error);
 wire phy_valid,phy_ready,rx_error;wire[7:0]phy_data;wire[4:0]level;
 uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) phy(.clk(clk),.rst(rst),.rx(rx),.valid(phy_valid),.ready(phy_ready),.data(phy_data),.framing_error(rx_error));
 wire byte_valid,byte_ready;wire[7:0]byte_data;
 uart_rx_fifo #(.DEPTH(FIFO_DEPTH)) fifo(.clk(clk),.rst(rst),.in_valid(phy_valid),.in_data(phy_data),.in_error(rx_error),.in_ready(phy_ready),.out_valid(byte_valid),.out_ready(byte_ready),.out_data(byte_data),.overflow(overflow),.framing_error(framing_error),.level(level));
 assign rx_valid=byte_valid;assign byte_ready=rx_ready;assign rx_data=byte_data;
endmodule
