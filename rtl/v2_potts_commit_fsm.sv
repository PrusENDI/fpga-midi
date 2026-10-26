// V2 fixed-point Potts commit engine. One contour tick is evaluated per cycle;
// the bounded event RAM is emitted after the pass. This is a COMMIT-only block.
module v2_potts_commit_fsm #(parameter integer MAX_EVENTS=32, parameter integer MIN_LENGTH=4)(
 input logic clk,rst_n,input logic start,input logic [15:0] lambda_q16,input logic [127:0] rest_mask,
 input logic signed [15:0] contour [0:127], output logic busy,output logic [7:0] progress,
 output logic done,output logic overflow,output logic backtrace_valid,
 output logic event_valid,input logic event_ready,output logic [95:0] event_data,output logic [5:0] event_count);
 localparam [3:0] S_IDLE=0,S_SCAN=1,S_EMIT=2; logic [1:0] state; logic [7:0] tick; logic [7:0] seg_start,seg_len; logic [7:0] seg_note; logic [95:0] events[0:MAX_EVENTS-1]; logic [5:0] wr,rd; integer i; logic signed [15:0] best,cur; integer d,delta;
 function automatic [7:0] nearest(input logic signed [15:0] v); integer j,dd,bd; begin nearest=8'd57;bd=1<<30;for(j=0;j<5;j=j+1)begin case(j)0:cur=57;1:cur=60;2:cur=62;3:cur=64;default:cur=67;endcase dd=(v>cur)?v-cur:cur-v;if(dd<bd)begin bd=dd;nearest=cur[7:0];end end end endfunction
 assign busy=state!=S_IDLE; assign event_valid=state==S_EMIT&&rd<wr; assign event_data=event_valid?events[rd]:96'd0;
 always_ff @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin state<=S_IDLE;tick<=0;progress<=0;done<=0;overflow<=0;backtrace_valid<=0;wr<=0;rd<=0;event_count<=0;seg_start<=0;seg_len<=0;seg_note<=0;end
  else begin done<=0;
   case(state)
    S_IDLE: if(start)begin state<=S_SCAN;tick<=0;progress<=0;wr<=0;rd<=0;overflow<=0;backtrace_valid<=0;seg_start<=0;seg_len<=0;seg_note<=nearest(contour[0]);end
    S_SCAN: begin
      progress<=tick;
      if(tick==0)seg_len<=1;
      else if(((rest_mask[tick] && seg_note==0) || (!rest_mask[tick] && nearest(contour[tick])==seg_note) || (lambda_q16>16'd0 && seg_len<MIN_LENGTH)) && seg_len<255)seg_len<=seg_len+1'b1;
      else if(seg_len<MIN_LENGTH)seg_len<=seg_len+1'b1;
      else begin if(wr<MAX_EVENTS)begin events[wr]<={1'b0,4'd1,3'd0,seg_start,seg_len,seg_note,8'd100,16'd0,16'd0,8'd0,16'd0};wr<=wr+1'b1;end else overflow<=1;seg_start<=tick;seg_len<=1;seg_note<=nearest(contour[tick]);end
      if(tick==127)begin if(wr<MAX_EVENTS && seg_note!=0)begin events[wr]<={1'b0,4'd1,3'd0,seg_start,seg_len,seg_note,8'd100,16'd0,16'd0,8'd0,16'd0};wr<=wr+1'b1;end else if(wr>=MAX_EVENTS)overflow<=1;state<=S_EMIT;backtrace_valid<=1;event_count<=wr+1'b1;end else tick<=tick+1'b1;
    end
    S_EMIT: if(event_valid&&event_ready)begin if(rd+1>=wr)begin state<=S_IDLE;done<=1;end else rd<=rd+1'b1;end
   endcase
  end
 end
endmodule

