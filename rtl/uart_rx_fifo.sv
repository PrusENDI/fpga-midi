// Small byte FIFO between the physical UART receiver and protocol parser.
// Overflow and framing errors are sticky until reset; accepted bytes retain
// their order and the FIFO applies backpressure to uart_rx.
module uart_rx_fifo #(
 parameter integer DEPTH=16
)(
 input wire clk,rst,
 input wire in_valid,input wire [7:0] in_data,input wire in_error,output wire in_ready,
 output wire out_valid,input wire out_ready,output wire [7:0] out_data,
 output reg overflow,output reg framing_error,output wire [4:0] level);
 localparam integer PW=(DEPTH<=2)?1:$clog2(DEPTH);
 reg [7:0] mem[0:DEPTH-1];reg [PW-1:0] wp,rp;reg [PW:0] count;
 wire push=in_valid&&in_ready;wire pop=out_valid&&out_ready;
 assign in_ready=count<DEPTH;assign out_valid=count!=0;assign out_data=mem[rp];assign level=count;
 always @(posedge clk) begin
  if(rst) begin wp<=0;rp<=0;count<=0;overflow<=0;framing_error<=0;end
  else begin
   if(in_valid&&!in_ready)overflow<=1;
   if(in_valid&&in_ready&&in_error)framing_error<=1;
   if(push)begin mem[wp]<=in_data;wp<=(wp==DEPTH-1)?0:wp+1'b1;end
   if(pop)rp<=(rp==DEPTH-1)?0:rp+1'b1;
   case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
  end
 end
endmodule
