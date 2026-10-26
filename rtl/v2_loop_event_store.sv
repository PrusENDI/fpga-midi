// Independent V2 two-bank, six-track, 16-slot append-only event store.
module v2_loop_event_store #(parameter integer TRACKS=6, parameter integer DEPTH=16)(
 input logic clk,rst_n,abort,loop_boundary,
 input logic ctrl_valid, output logic ctrl_ready, input logic [2:0] ctrl_op, input logic [2:0] ctrl_track, output logic ctrl_done,
 input logic write_valid, output logic write_ready, input logic [2:0] write_track, input logic [3:0] write_slot, input logic [95:0] write_data,
 input logic read_enable, input logic [2:0] read_track, input logic [3:0] read_index, output logic read_valid, output logic read_slot_valid, output logic [95:0] read_data,
 output logic active_bank, output logic shadow_bank, output logic commit_pending, output logic commit_ack, output logic busy,
 output logic [29:0] record_count, output logic [5:0] overflow, output logic active_valid);
  localparam logic [2:0] PREPARE_OVERDUB=3'd0, CLEAR_TRACK=3'd1, CLEAR_ALL=3'd2,
                         COMMIT_REQUEST=3'd3, ABORT_CMD=3'd4, PREPARE_RECORD=3'd5;
  logic [95:0] mem [0:1][0:TRACKS-1][0:DEPTH-1];
  logic [4:0] counts [0:1][0:TRACKS-1];
  logic [6:0] copy_index; logic copy_active, copy_record; logic [2:0] copy_track;
  logic [95:0] read_reg; integer b,t;
  assign shadow_bank=~active_bank; assign busy=copy_active||commit_pending;
  assign ctrl_ready=rst_n&&!abort&&(!busy || ctrl_op==ABORT_CMD);
  assign write_ready=rst_n&&!abort&&!busy&&!ctrl_valid&&(write_track<TRACKS)&&
    (write_slot==counts[shadow_bank][write_track])&&(counts[shadow_bank][write_track]<DEPTH);
  assign read_data=read_slot_valid?read_reg:96'd0;
  assign active_valid=(|counts[active_bank][0])||(|counts[active_bank][1])||(|counts[active_bank][2])||
    (|counts[active_bank][3])||(|counts[active_bank][4])||(|counts[active_bank][5]);
  always_comb begin record_count='0; for (integer k=0;k<TRACKS;k=k+1) record_count[k*5 +: 5]=counts[shadow_bank][k]; end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin active_bank<=0;copy_active<=0;copy_record<=0;copy_track<=0;copy_index<=0;commit_pending<=0;commit_ack<=0;ctrl_done<=0;read_valid<=0;read_slot_valid<=0;read_reg<=0;overflow<=0;for(b=0;b<2;b=b+1)for(t=0;t<TRACKS;t=t+1)counts[b][t]<=0; end
    else begin
      ctrl_done<=0;commit_ack<=0;read_valid<=0;read_slot_valid<=0;
      if(abort) begin copy_active<=0;commit_pending<=0;overflow<=0;for(t=0;t<TRACKS;t=t+1)counts[shadow_bank][t]<=0; end
      else if(ctrl_valid&&ctrl_ready&&ctrl_op==ABORT_CMD) begin
        copy_active<=0; commit_pending<=0; overflow<=0; ctrl_done<=1;
        for(t=0;t<TRACKS;t=t+1) counts[shadow_bank][t]<=0;
      end else if(copy_active) begin
        mem[shadow_bank][copy_index/DEPTH][copy_index%DEPTH]<=mem[active_bank][copy_index/DEPTH][copy_index%DEPTH];
        if(copy_index==TRACKS*DEPTH-1) begin copy_active<=0;ctrl_done<=1;if(copy_record)counts[shadow_bank][copy_track]<=0;end else copy_index<=copy_index+1'b1;
      end else if(commit_pending&&loop_boundary) begin
        active_bank<=shadow_bank;commit_pending<=0;commit_ack<=1;overflow<=0;for(t=0;t<TRACKS;t=t+1)counts[active_bank][t]<=0;
      end else if(ctrl_valid&&ctrl_ready) begin
        case(ctrl_op)
          PREPARE_OVERDUB: begin copy_active<=1;copy_record<=0;copy_index<=0;for(t=0;t<TRACKS;t=t+1)counts[shadow_bank][t]<=counts[active_bank][t];end
          PREPARE_RECORD: begin copy_active<=1;copy_record<=1;copy_track<=ctrl_track;copy_index<=0;for(t=0;t<TRACKS;t=t+1)counts[shadow_bank][t]<=counts[active_bank][t];end
          CLEAR_TRACK: begin ctrl_done<=1;if(ctrl_track<TRACKS)begin counts[shadow_bank][ctrl_track]<=0;overflow[ctrl_track]<=0;end end
          CLEAR_ALL: begin ctrl_done<=1;for(t=0;t<TRACKS;t=t+1)counts[shadow_bank][t]<=0;overflow<=0;end
          COMMIT_REQUEST: begin ctrl_done<=1;commit_pending<=1;end
          ABORT_CMD: begin ctrl_done<=1;commit_pending<=0;overflow<=0;for(t=0;t<TRACKS;t=t+1)counts[shadow_bank][t]<=0;end
          default: ctrl_done<=1;
        endcase
      end else begin
        if(write_valid&&!write_ready&&write_track<TRACKS&&counts[shadow_bank][write_track]>=DEPTH)overflow[write_track]<=1;
        if(write_valid&&write_ready)begin mem[shadow_bank][write_track][write_slot]<=write_data;counts[shadow_bank][write_track]<=counts[shadow_bank][write_track]+1'b1;end
      end
      if(read_enable&&!busy&&read_track<TRACKS)begin read_valid<=1;read_slot_valid<=read_index<counts[active_bank][read_track];read_reg<=mem[active_bank][read_track][read_index];end
    end
  end
endmodule
