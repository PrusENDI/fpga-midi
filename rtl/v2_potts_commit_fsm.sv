// Bounded fixed-point Potts DP: one (end,start,degree) cell is evaluated per
// clock. Costs saturate at 63'h3fff...; ties prefer longer segments then lower
// degree. Backpointers are traced before the held event stream is published.
module v2_potts_commit_fsm #(parameter integer MAX_EVENTS=32, parameter integer MIN_LENGTH=4)(
 input logic clk,rst_n,input logic start,input logic [15:0] lambda_q16,input logic [127:0] rest_mask,
 input logic signed [15:0] contour [0:127], output logic busy,output logic [7:0] progress,
 output logic done,output logic overflow,output logic backtrace_valid,output logic event_valid,
 input logic event_ready,output logic [95:0] event_data,output logic [5:0] event_count);
 localparam [2:0] IDLE=0,CELL=1,SEGMENT=2,CELL_COMMIT=3,TRACE=4,EMIT=5; logic [2:0] state; integer e,s,d,t,seg_t; integer signed cost,err,sum,err_acc; integer has_rest,has_data,has_rest_acc,has_data_acc; integer trace_end,trace_start,trace_deg; logic [31:0] dp[0:128]; logic [7:0] bp_s[0:128],bp_d[0:128]; logic [95:0] events[0:MAX_EVENTS-1]; logic [5:0] wr,rd; logic [95:0] temp_event;
 function automatic integer note(input integer k); case(k)0:note=57;1:note=60;2:note=62;3:note=64;default:note=67;endcase endfunction
 function automatic integer sat(input integer v); if(v>32'sh3fffffff)sat=32'sh3fffffff; else if(v<0)sat=0; else sat=v; endfunction
 assign busy=state!=IDLE; assign event_valid=state==EMIT&&rd<wr; assign event_data=event_valid?events[rd]:96'd0;
 always_ff @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin state<=IDLE;done<=0;overflow<=0;backtrace_valid<=0;progress<=0;e<=0;s<=0;d<=0;wr<=0;rd<=0;event_count<=0;end else begin done<=0;
   case(state)
    IDLE: if(start)begin state<=CELL;e<=1;s<=0;d<=0;dp[0]<=0;for(t=1;t<=128;t=t+1)dp[t]<=32'h3fffffff;wr<=0;rd<=0;overflow<=0;backtrace_valid<=0;progress<=0;end
    CELL: begin
      err_acc=0; has_rest_acc=0; has_data_acc=0; seg_t=s; state<=SEGMENT;
    end
    SEGMENT: begin
      if (seg_t < e) begin
        if (rest_mask[seg_t]) has_rest_acc=1;
        else begin
          has_data_acc=1;
          err_acc=err_acc+(contour[seg_t]-note(d))*(contour[seg_t]-note(d));
        end
        seg_t=seg_t+1;
      end else state<=CELL_COMMIT;
    end
    CELL_COMMIT: begin
      err=err_acc; has_rest=has_rest_acc; has_data=has_data_acc;
      if(err>32'sh3fffffff)err=32'sh3fffffff;
      cost=dp[s]+err+((s==0)?0:lambda_q16); if((has_rest==0 || has_data==0) && ((e-s)>=MIN_LENGTH || s==0))begin if(cost<dp[e] || (cost==dp[e]&&((e-s)>=(e-bp_s[e]))))begin dp[e]<=sat(cost);bp_s[e]<=s[7:0];bp_d[e]<=d[7:0];end end
      if(d==4)begin d<=0;if(s==e-1)begin s<=0;e<=e+1;progress<=e;end else s<=s+1;end else d<=d+1;
      if(e==128&&s==127&&d==4)begin state<=TRACE;trace_end<=128;wr<=0;end
      else state<=CELL;
    end
    TRACE: begin
      if(trace_end==0)begin backtrace_valid<=1;event_count<=wr;state<=EMIT;rd<=0;end
      else begin trace_start=bp_s[trace_end];trace_deg=bp_d[trace_end];if(!rest_mask[trace_start]&&wr<MAX_EVENTS)begin temp_event=0;temp_event[94:91]=4'd1;temp_event[87:80]=trace_start;temp_event[79:72]=trace_end-trace_start;temp_event[71:64]=note(trace_deg);temp_event[63:56]=8'd100;events[wr]<=temp_event;wr<=wr+1;end else if(wr>=MAX_EVENTS)overflow<=1;trace_end<=trace_start;end
    end
    EMIT: if(event_valid&&event_ready)begin if(rd+1>=wr)begin state<=IDLE;done<=1;end else rd<=rd+1;end
   endcase
  end
 end
endmodule
