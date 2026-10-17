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
 localparam [PW-1:0] LAST_PTR=DEPTH-1;
 localparam [PW:0] DEPTH_COUNT=DEPTH;
 // Keep this tiny UART FIFO in ordinary registers.  Gowin synthesis can
 // infer an asynchronous RAM from an indexed unpacked array here, then
 // legally optimize away the byte read path because the RAM has no clocked
 // read port.  The protocol consumer needs the byte in the same cycle as
 // out_valid, so an explicit register bank is the portable implementation.
 reg [7:0] mem0,mem1,mem2,mem3,mem4,mem5,mem6,mem7;
 reg [7:0] mem8,mem9,mem10,mem11,mem12,mem13,mem14,mem15;
 reg [PW-1:0] wp,rp;reg [PW:0] count;
 wire push=in_valid&&in_ready;wire pop=out_valid&&out_ready;
 assign in_ready=count<DEPTH_COUNT;assign out_valid=count!=0;assign level=count;
 reg [7:0] out_data_reg;
 always @* begin
  case (rp)
   0:out_data_reg=mem0; 1:out_data_reg=mem1; 2:out_data_reg=mem2; 3:out_data_reg=mem3;
   4:out_data_reg=mem4; 5:out_data_reg=mem5; 6:out_data_reg=mem6; 7:out_data_reg=mem7;
   8:out_data_reg=mem8; 9:out_data_reg=mem9; 10:out_data_reg=mem10; 11:out_data_reg=mem11;
   12:out_data_reg=mem12; 13:out_data_reg=mem13; 14:out_data_reg=mem14; 15:out_data_reg=mem15;
   default:out_data_reg=8'h00;
  endcase
 end
 assign out_data=out_data_reg;
 always @(posedge clk) begin
  if(rst) begin wp<=0;rp<=0;count<=0;overflow<=0;framing_error<=0;
   mem0<=0;mem1<=0;mem2<=0;mem3<=0;mem4<=0;mem5<=0;mem6<=0;mem7<=0;
   mem8<=0;mem9<=0;mem10<=0;mem11<=0;mem12<=0;mem13<=0;mem14<=0;mem15<=0;
  end
  else begin
   if(in_valid&&!in_ready)overflow<=1;
   if(in_valid&&in_ready&&in_error)framing_error<=1;
   if(push) begin
    case (wp)
     0:mem0<=in_data; 1:mem1<=in_data; 2:mem2<=in_data; 3:mem3<=in_data;
     4:mem4<=in_data; 5:mem5<=in_data; 6:mem6<=in_data; 7:mem7<=in_data;
     8:mem8<=in_data; 9:mem9<=in_data; 10:mem10<=in_data; 11:mem11<=in_data;
     12:mem12<=in_data; 13:mem13<=in_data; 14:mem14<=in_data; 15:mem15<=in_data;
     default:;
    endcase
    wp<=(wp==LAST_PTR)?{PW{1'b0}}:wp+{{(PW-1){1'b0}},1'b1};
   end
   if(pop)rp<=(rp==LAST_PTR)?{PW{1'b0}}:rp+{{(PW-1){1'b0}},1'b1};
   case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
  end
 end
endmodule
