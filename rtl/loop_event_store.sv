// Fixed 2-bank x 4-track x 16-slot append-only event store.
// ctrl_valid/data must hold until ctrl_ready. ctrl_done marks command completion;
// COMMIT_REQUEST completes when armed, commit_ack marks the later actual swap.
// All read requests complete after their sampling edge (one synchronous RAM
// cycle). A request on a swap edge is cancelled: read_valid=0. Retry it against
// the new active bank. Invalid slots return zero, regardless of RAM contents.
// Reset/abort/clear change metadata only. Aborting preserves active playback.
// Empty banks can commit, so CLEAR_ALL can take effect. The mode manager must
// ABORT an empty recording when policy requires retaining the old Loop.
module loop_event_store #(
  parameter USE_GOWIN_RAM = 1
)(
  input wire clk, input wire rst_n, input wire abort,
  input wire loop_boundary,
  input wire ctrl_valid, output wire ctrl_ready,
  input wire [2:0] ctrl_op, input wire [1:0] ctrl_track,
  output reg ctrl_done,
  input wire write_valid, output wire write_ready,
  input wire [1:0] write_track, input wire [3:0] write_slot,
  input wire [63:0] write_data,
  input wire read_enable, input wire [5:0] read_index,
  output reg read_valid, output reg read_slot_valid,
  output wire [63:0] read_data,
  output reg active_bank, output wire shadow_bank,
  output reg commit_pending, output reg commit_ack,
  output wire busy, output wire [19:0] record_count,
  output reg [3:0] overflow, output wire active_valid
);
  localparam [2:0] PREPARE_OVERDUB=0, CLEAR_TRACK=1, CLEAR_ALL=2,
                   COMMIT_REQUEST=3, ABORT=4, PREPARE_RECORD=5;
  localparam [1:0] IDLE=0, COPY_READ=1, COPY_WRITE=2;
  reg [1:0] state;
  // Appending and whole-track clears maintain contiguous valid slots. Counts
  // are therefore also the validity map; RAM words are never reset.
  reg [4:0] counts [0:1][0:3];
  reg [5:0] copy_index;
  reg copy_record;
  reg [1:0] copy_track;
  wire command_abort = ctrl_valid && ctrl_ready && ctrl_op==ABORT;
  wire cancelling = abort || command_abort;
  wire swapping = commit_pending && loop_boundary && !cancelling;
  assign shadow_bank = !active_bank;
  assign active_valid = (counts[active_bank][0]!=0) || (counts[active_bank][1]!=0) ||
                        (counts[active_bank][2]!=0) || (counts[active_bank][3]!=0);
  assign busy = (state!=IDLE) || commit_pending;
  assign ctrl_ready = rst_n && !abort && ((ctrl_op==ABORT) || !busy);
  assign write_ready = rst_n && !abort && !busy && !ctrl_valid &&
                       counts[shadow_bank][write_track]<16 &&
                       {1'b0,write_slot}==counts[shadow_bank][write_track];
  genvar g;
  generate for(g=0;g<4;g=g+1) begin: status_counts
    assign record_count[g*5 +: 5] = counts[shadow_bank][g];
  end endgenerate

  reg a_en,a_we;
  reg [6:0] a_addr;
  reg [63:0] a_wdata;
  wire [63:0] a_rdata,b_rdata;
  always @* begin
    a_en=0; a_we=0; a_addr=0; a_wdata=0;
    if(rst_n && !cancelling) begin
      case(state)
        COPY_READ: begin a_en=1; a_addr={active_bank,copy_index}; end
        COPY_WRITE: begin
          a_en=1; a_we=1; a_addr={shadow_bank,copy_index}; a_wdata=a_rdata;
        end
        default: if(write_valid && write_ready) begin
          a_en=1; a_we=1; a_addr={shadow_bank,write_track,write_slot}; a_wdata=write_data;
        end
      endcase
    end
  end
  loop_event_ram #(.USE_GOWIN_RAM(USE_GOWIN_RAM)) ram (
    .clk(clk), .a_en(a_en), .a_we(a_we), .a_addr(a_addr),
    .a_wdata(a_wdata), .a_rdata(a_rdata),
    .b_en(read_enable && rst_n && !swapping), .b_we(1'b0),
    .b_addr({active_bank,read_index}), .b_wdata(64'b0), .b_rdata(b_rdata)
  );
  assign read_data = read_slot_valid ? b_rdata : 64'b0;
  integer bank,track;
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      active_bank<=0;commit_pending<=0;commit_ack<=0;ctrl_done<=0;
      state<=IDLE;copy_index<=0;copy_record<=0;copy_track<=0;
      overflow<=0;read_valid<=0;read_slot_valid<=0;
      for(bank=0;bank<2;bank=bank+1)
        for(track=0;track<4;track=track+1) counts[bank][track]<=0;
    end else begin
      ctrl_done<=0;commit_ack<=0;
      read_valid<=read_enable && !swapping;
      read_slot_valid<=read_enable && !swapping &&
                       ({1'b0,read_index[3:0]} < counts[active_bank][read_index[5:4]]);
      if(cancelling) begin
        state<=IDLE;commit_pending<=0;overflow<=0;
        ctrl_done<=command_abort;
        for(track=0;track<4;track=track+1) counts[shadow_bank][track]<=0;
      end else if(swapping) begin
        active_bank<=shadow_bank;commit_pending<=0;commit_ack<=1;overflow<=0;
        // The retired active bank becomes an empty editing bank.
        for(track=0;track<4;track=track+1) counts[active_bank][track]<=0;
      end else if(state==COPY_READ) begin
        state<=COPY_WRITE;
      end else if(state==COPY_WRITE) begin
        if(copy_index==63) begin
          state<=IDLE;ctrl_done<=1;
          for(track=0;track<4;track=track+1)
            if(copy_record && track==copy_track) counts[shadow_bank][track]<=0;
            else counts[shadow_bank][track]<=counts[active_bank][track];
        end else begin copy_index<=copy_index+1'b1;state<=COPY_READ;end
      end else if(ctrl_valid && ctrl_ready) begin
        ctrl_done<=1;
        case(ctrl_op)
          PREPARE_OVERDUB,PREPARE_RECORD: begin
            state<=COPY_READ;copy_index<=0;copy_record<=(ctrl_op==PREPARE_RECORD);
            copy_track<=ctrl_track;overflow<=0;ctrl_done<=0;
            for(track=0;track<4;track=track+1) counts[shadow_bank][track]<=0;
          end
          CLEAR_TRACK: begin counts[shadow_bank][ctrl_track]<=0;overflow[ctrl_track]<=0;end
          CLEAR_ALL: begin
            for(track=0;track<4;track=track+1) counts[shadow_bank][track]<=0;
            overflow<=0;
          end
          COMMIT_REQUEST: commit_pending<=1;
          default: begin end // Reserved commands complete without mutation.
        endcase
      end else if(!busy && !ctrl_valid && write_valid) begin
        if(write_ready) counts[shadow_bank][write_track]<=counts[shadow_bank][write_track]+1'b1;
        // Full-track attempts are diagnostic; waiting during copy/commit is not.
        else if(counts[shadow_bank][write_track]==16) overflow[write_track]<=1;
      end
    end
  end
endmodule
