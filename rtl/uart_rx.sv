// 8N1 UART receiver. One byte is held until ready; framing errors are
// reported with the byte and the receiver returns to idle for self-recovery.
module uart_rx #(
 parameter integer CLK_HZ=50_000_000,
 parameter integer BAUD=115_200
)(
 input wire clk,rst,input wire rx,
 output reg valid,input wire ready,output reg [7:0] data,output reg framing_error);
 localparam integer CLKS_PER_BIT=CLK_HZ/BAUD;
 localparam integer HALF_BIT=(CLKS_PER_BIT<2)?1:(CLKS_PER_BIT/2);
 reg [15:0] count;reg [3:0] bit_index;reg active;reg [7:0] shift;
 reg rx_meta,rx_sync;
 always @(posedge clk) begin
  if(rst) begin rx_meta<=1;rx_sync<=1;valid<=0;data<=0;framing_error<=0;count<=0;bit_index<=0;active<=0;shift<=0;end
  else begin
   rx_meta<=rx;rx_sync<=rx_meta;
   if(valid && ready) begin valid<=0;framing_error<=0;end
   if(!active && !valid && !rx_sync) begin active<=1;count<=HALF_BIT-1;bit_index<=0;shift<=0;end
   else if(active) begin
    if(count!=0) count<=count-1;
    else begin
     count<=CLKS_PER_BIT-1;
     if(bit_index==0) begin
      if(!rx_sync) bit_index<=1; else active<=0;
     end else if(bit_index<=8) begin
      shift[bit_index-1]<=rx_sync;bit_index<=bit_index+1'b1;
     end else begin
      active<=0;
      if(rx_sync) begin data<=shift;valid<=1;end
      else begin framing_error<=1;data<=shift;valid<=1;end
     end
    end
   end
  end
 end
endmodule
