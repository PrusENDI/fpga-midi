// Independent V2 six-track, two-bank event store.  Each bank has 6x16 96-bit
// slots; metadata counts provide validity and make abort/clear non-destructive.
module v2_loop_event_store #(
  parameter integer TRACKS=6, parameter integer DEPTH=16
) (
  input logic clk,rst_n,abort,loop_boundary,
  input logic ctrl_valid, output logic ctrl_ready, input logic [2:0] ctrl_op,
  input logic [2:0] ctrl_track, output logic ctrl_done,
  input logic write_valid, output logic write_ready, input logic [2:0] write_track,
  input logic [3:0] write_slot, input logic [95:0] write_data,
  input logic read_enable, input logic [3:0] read_index, output logic read_valid,
  output logic read_slot_valid, output logic [95:0] read_data,
  output logic active_bank, output logic shadow_bank, output logic commit_pending,
  output logic commit_ack, output logic busy, output logic [6:0] record_count,
  output logic [5:0] overflow, output logic active_valid
);
  localparam [2:0] OP_CLEAR_TRACK=1,OP_CLEAR_ALL=2,OP_COMMIT=3,OP_ABORT=4,OP_RECORD=5;
  logic [95:0] mem[0:1][0:TRACKS-1][0:DEPTH-1]; logic [4:0] counts[0:1][0:TRACKS-1];
  logic [95:0] read_reg; integer b,t;
  assign shadow_bank=!active_bank; assign busy=commit_pending;
  assign active_valid=|counts[active_bank][0]|| |counts[active_bank][1]|| |counts[active_bank][2]|| |counts[active_bank][3]|| |counts[active_bank][4]|| |counts[active_bank][5];
  assign ctrl_ready=rst_n&&!abort&&!commit_pending;
  assign write_ready=rst_n&&!abort&&!commit_pending&&!ctrl_valid&&(write_track<TRACKS)&&(counts[shadow_bank][write_track]<DEPTH)&&(write_slot==counts[shadow_bank][write_track]);
  assign record_count=counts[shadow_bank][0]; assign read_data=read_slot_valid?read_reg:96'd0;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin active_bank<=0;commit_pending<=0;commit_ack<=0;ctrl_done<=0;read_valid<=0;read_slot_valid<=0;overflow<=0;read_reg<=0; for(b=0;b<2;b++)for(t=0;t<TRACKS;t++)counts[b][t]<=0; end
    else begin
      ctrl_done<=0;commit_ack<=0;read_valid<=0;read_slot_valid<=0;
      if(abort) begin commit_pending<=0; overflow<=0; for(t=0;t<TRACKS;t++)counts[shadow_bank][t]<=0; end
      else if(commit_pending&&loop_boundary) begin active_bank<=shadow_bank;commit_pending<=0;commit_ack<=1;overflow<=0;for(t=0;t<TRACKS;t++)counts[active_bank][t]<=0; end
      else if(ctrl_valid&&ctrl_ready) begin ctrl_done<=1; case(ctrl_op)
        OP_CLEAR_TRACK: begin if(ctrl_track<TRACKS) counts[shadow_bank][ctrl_track]<=0; end
        OP_CLEAR_ALL,OP_RECORD: begin for(t=0;t<TRACKS;t++)counts[shadow_bank][t]<=0; end
        OP_COMMIT: commit_pending<=1;
        OP_ABORT: begin commit_pending<=0; for(t=0;t<TRACKS;t++)counts[shadow_bank][t]<=0; end
      endcase end
      else if(write_valid&&!write_ready&&write_track<TRACKS&&counts[shadow_bank][write_track]>=DEPTH) overflow[write_track]<=1;
      if(write_valid&&write_ready) begin mem[shadow_bank][write_track][write_slot]<=write_data;counts[shadow_bank][write_track]<=counts[shadow_bank][write_track]+1'b1;end
      if(read_enable&&!commit_pending) begin read_valid<=1;read_slot_valid<=read_index<counts[active_bank][0];read_reg<=mem[active_bank][0][read_index];end
    end
  end
endmodule
