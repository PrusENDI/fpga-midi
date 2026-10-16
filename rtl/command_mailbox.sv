module command_mailbox #(
 parameter integer RX_TIMEOUT_CYCLES=500000
)(
 input wire clk, input wire rst_n,
 input wire rx_valid, output wire rx_ready, input wire [7:0] rx_data,
 output wire tx_valid, input wire tx_ready, output wire [7:0] tx_data,
 output reg csr_valid, input wire csr_ready, output reg csr_write,
 output reg [7:0] csr_addr, output reg [31:0] csr_wdata,
 input wire csr_rsp_valid, output wire csr_rsp_ready,
 input wire [7:0] csr_rsp_status, input wire [31:0] csr_rsp_rdata,
 output reg urgent_stop
);
 import control_protocol_pkg::*;
 // One parsed frame and four complete replies bound storage. Parsing continues
 // while a CSR or TX is stalled, so a following STOP/RESET can assert urgent.
 reg [3:0] rx_index;
 reg [31:0] idle_cycles;
 reg [7:0] op,length_byte,seq,checksum;
 reg [31:0] arguments;
 reg frame_valid;
 reg [7:0] frame_status;
 reg outstanding,request_sent;
 reg [7:0] active_op,active_seq;
 reg [79:0] replies[0:3];
 reg [1:0] rd_ptr,wr_ptr;
 reg [2:0] reply_count;
 reg [3:0] tx_index;
 reg mapped,read_args_ok;
 reg [7:0] mapped_addr;
 reg mapped_write;
 wire room=(reply_count<4);
 wire pop=tx_valid && tx_ready && tx_index==9;
 wire take_response=csr_rsp_valid && csr_rsp_ready;
 wire take_frame=frame_valid && room && !take_response &&
                  (frame_status!=ACK_ACCEPTED || !outstanding);
 wire push=take_response || take_frame;
 assign rx_ready=!frame_valid;
 assign tx_valid=(reply_count!=0);
 assign tx_data=replies[rd_ptr][tx_index*8 +: 8];
 assign csr_rsp_ready=outstanding && request_sent && room;
 function automatic [79:0] reply(input [7:0] opcode,input [7:0] status,
                               input [31:0] data,input [7:0] sequence_id);
  reg [7:0] check;
  begin
   check=opcode^status^data[7:0]^data[15:8]^data[23:16]^data[31:24]^sequence_id;
   reply={check,sequence_id,data,status,opcode,8'h55,8'haa};
  end
 endfunction
 always @* begin
  mapped=1; mapped_addr=CSR_STATUS; mapped_write=1;
  read_args_ok=(arguments[31:8]==0);
  case(op)
   CMD_STATUS:begin mapped_addr=CSR_STATUS;mapped_write=0;end
   CMD_SET_MODE:mapped_addr=CSR_MODE;
   CMD_SET_BPM:mapped_addr=CSR_BPM;
   CMD_SELECT_TRACK:mapped_addr=CSR_TRACK;
   CMD_PLAY:mapped_addr=CSR_PLAY;
   CMD_STOP:mapped_addr=CSR_STOP;
   CMD_RECORD:mapped_addr=CSR_RECORD;
   CMD_OVERDUB:mapped_addr=CSR_OVERDUB;
   CMD_CLEAR_TRACK:mapped_addr=CSR_CLEAR_TRACK;
   CMD_CLEAR_ALL:mapped_addr=CSR_CLEAR_ALL;
   CMD_COMMIT:mapped_addr=CSR_COMMIT;
   CMD_RESET:mapped_addr=CSR_RESET;
   CMD_READ_CSR:begin mapped_addr=arguments[7:0];mapped_write=0;end
   CMD_SET_THRESHOLDS:mapped_addr=CSR_THRESHOLDS;
   default:mapped=0;
  endcase
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   rx_index<=0;idle_cycles<=0;op<=0;length_byte<=0;seq<=0;checksum<=0;arguments<=0;
   frame_valid<=0;frame_status<=ACK_ACCEPTED;
   outstanding<=0;request_sent<=0;active_op<=0;active_seq<=0;
   rd_ptr<=0;wr_ptr<=0;reply_count<=0;tx_index<=0;
   csr_valid<=0;csr_write<=0;csr_addr<=0;csr_wdata<=0;urgent_stop<=0;
  end else begin
   case({push,pop})
    2'b10:reply_count<=reply_count+1'b1;
    2'b01:reply_count<=reply_count-1'b1;
    default:;
   endcase
   if(tx_valid && tx_ready) begin
    if(pop)begin rd_ptr<=rd_ptr+1'b1;tx_index<=0;end
    else tx_index<=tx_index+1'b1;
   end
   if(push)wr_ptr<=wr_ptr+1'b1;
   if(csr_valid && csr_ready) begin
    csr_valid<=0;request_sent<=1;
    if(active_op==CMD_STOP || active_op==CMD_RESET)urgent_stop<=0;
   end
   if(take_response)begin
    replies[wr_ptr]<=reply(active_op,csr_rsp_status,csr_rsp_rdata,active_seq);
    outstanding<=0;request_sent<=0;
   end
   if(take_frame)begin
    frame_valid<=0;
    replies[wr_ptr]<=reply(op,frame_status,0,seq);
    if(frame_status==ACK_ACCEPTED)begin
     outstanding<=1;request_sent<=0;active_op<=op;active_seq<=seq;
     csr_valid<=1;csr_write<=mapped_write;csr_addr<=mapped_addr;csr_wdata<=arguments;
    end
   end
   // Incomplete frames expire silently. Header search allows 55 55 AA.
   if(rx_ready)begin
    if(rx_valid)begin
     idle_cycles<=0;
     case(rx_index)
      0:if(rx_data==8'h55)rx_index<=1;
      1:if(rx_data==8'haa)begin rx_index<=2;checksum<=0;end
        else if(rx_data!=8'h55)rx_index<=0;
      2:begin op<=rx_data;checksum<=rx_data;rx_index<=3;end
      3:begin length_byte<=rx_data;checksum<=checksum^rx_data;rx_index<=4;end
      4,5,6,7:begin arguments[(rx_index-4)*8 +: 8]<=rx_data;
                    checksum<=checksum^rx_data;rx_index<=rx_index+1'b1;end
      8:begin seq<=rx_data;checksum<=checksum^rx_data;rx_index<=9;end
      9:begin
       rx_index<=0;frame_valid<=1;
       // Validation precedes BUSY; bad frames never issue ACCEPTED or CSR.
       if(checksum!=rx_data || length_byte!=4)frame_status<=ACK_ERROR;
       else if(!mapped || (op==CMD_READ_CSR && !read_args_ok))frame_status<=ACK_REJECTED;
       else if((op==CMD_STOP || op==CMD_RESET) && arguments!=0)frame_status<=ACK_REJECTED;
       else if(op==CMD_STOP || op==CMD_RESET)begin
        frame_status<=ACK_ACCEPTED;urgent_stop<=1;
       end else if(outstanding)frame_status<=ACK_BUSY;
       else frame_status<=ACK_ACCEPTED;
      end
      default:rx_index<=0;
     endcase
    end else if(rx_index!=0)begin
     if(idle_cycles>=RX_TIMEOUT_CYCLES-1)begin rx_index<=0;idle_cycles<=0;end
     else idle_cycles<=idle_cycles+1'b1;
    end
   end
  end
 end
endmodule
