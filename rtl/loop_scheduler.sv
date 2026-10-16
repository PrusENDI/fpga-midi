// 128 sixteenth-note intervals per loop. The current tick changes only at a
// musical deadline, never when a scan completes. Each scan has three global
// passes: OFF (explicit or duration end), ON, then CONTROL.
module loop_scheduler #(
  parameter integer CLK_HZ = 50_000_000,
  parameter integer READ_TIMEOUT_CYCLES = 16
)(
  input wire clk, input wire rst_n,
  input wire run, input wire stop, input wire flush, input wire reset_position,
  input wire [15:0] bpm_value,
  output wire read_enable, output wire [5:0] read_index,
  input wire read_valid, input wire read_slot_valid, input wire [63:0] read_data,
  output wire event_valid, input wire event_ready, output wire [63:0] event_data,
  output reg sixteenth_ce, output reg [6:0] loop_tick,
  output reg loop_boundary, output wire stall,
  output reg fault_valid, output reg [7:0] fault_code, output reg [31:0] fault_info,
  output reg heartbeat_toggle, output reg [15:0] active_bpm
);
  // Constant division occurs at elaboration only. A Q16 scale followed by
  // rounding gives steps 344 / 1031 at 50 MHz and BPM 60 / 180 respectively.
  localparam [63:0] PHASE_SCALE_Q16 = 64'd281474976710656 / (64'd15 * CLK_HZ);
  localparam [3:0] IDLE=0, REQUEST=1, RESPONSE=2, SEND=3, WAIT_TICK=4,
                   BOUND_OFF=5, BOUND_MARK=6, SWAP_WAIT=7, RELEASE=8;
  localparam integer TIMEOUT_BITS = (READ_TIMEOUT_CYCLES<2) ? 1 : $clog2(READ_TIMEOUT_CYCLES);
  reg [3:0] state;
  reg running,run_d,cancel_seen,pending_start;
  reg [31:0] phase,phase_step;
  reg [5:0] slot;
  reg [1:0] pass;
  reg [TIMEOUT_BITS-1:0] read_wait;
  reg [63:0] pending_data;
  wire [32:0] phase_sum={1'b0,phase}+{1'b0,phase_step};
  wire cancelling=stop || flush || reset_position || (run_d && !run);
  wire deadline=running && phase_sum[32];
  wire overrun=deadline && state!=WAIT_TICK;
  wire read_timeout=state==RESPONSE && !read_valid && read_wait==READ_TIMEOUT_CYCLES-1;
  wire [7:0] end_tick={1'b0,read_data[11:5]}+{1'b0,read_data[18:12]};
  wire derived_off=read_data[2:0]==0 && read_data[18:12]!=0 && !end_tick[7] && end_tick[6:0]==loop_tick;
  wire explicit_match=read_data[11:5]==loop_tick;
  wire match_event=read_slot_valid &&
    ((pass==0 && ((read_data[2:0]==1 && explicit_match) || derived_off)) ||
     (pass==1 && read_data[2:0]==0 && explicit_match) ||
     (pass==2 && read_data[2:0]==2 && explicit_match));
  wire output_state=state==SEND || state==BOUND_OFF || state==BOUND_MARK || state==RELEASE;
  // Cancellation is a documented valid/data stability exception: an old ON
  // must not handshake on the very edge that STOP or a deadline fault arrives.
  assign event_valid=rst_n && output_state &&
                     (state==RELEASE || (!cancelling && !overrun));
  assign event_data=state==RELEASE || state==BOUND_OFF ? 64'd4 :
                    state==BOUND_MARK ? 64'd3 : pending_data;
  assign stall=event_valid && !event_ready;
  assign read_enable=rst_n && state==REQUEST && !cancelling && !overrun;
  assign read_index=slot;

  function [31:0] bpm_step(input [15:0] bpm);
    reg [63:0] product;
    begin product=bpm*PHASE_SCALE_Q16+64'd32768; bpm_step=product[47:16]; end
  endfunction
  task next_slot;
    begin
      if(slot==63) begin
        slot<=0;
        if(pass==2) state<=WAIT_TICK;
        else begin pass<=pass+1'b1;state<=REQUEST;end
      end else begin slot<=slot+1'b1;state<=REQUEST;end
    end
  endtask
  task halt_fault(input [7:0] code,input [31:0] info);
    begin
      if(!fault_valid) begin fault_valid<=1;fault_code<=code;fault_info<=info;end
      running<=0;phase<=0;loop_tick<=0;state<=RELEASE;pending_start<=0;
    end
  endtask
  // This bound leaves enough time for all 192 reads plus event handshakes at
  // BPM180. Downstream stalls still have a hard musical deadline.
  initial begin
    if(CLK_HZ<10000) $error("loop_scheduler CLK_HZ must be at least 10000");
    if(READ_TIMEOUT_CYCLES<1) $error("READ_TIMEOUT_CYCLES must be positive");
  end
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      state<=IDLE;running<=0;run_d<=0;cancel_seen<=0;pending_start<=0;
      phase<=0;phase_step<=0;slot<=0;pass<=0;read_wait<=0;pending_data<=0;
      sixteenth_ce<=0;loop_tick<=0;loop_boundary<=0;
      fault_valid<=0;fault_code<=0;fault_info<=0;heartbeat_toggle<=0;active_bpm<=60;
    end else begin
      run_d<=run;cancel_seen<=cancelling;
      // Preserve a fresh PLAY edge while an earlier ALL_NOTES_OFF awaits
      // acceptance. Cancellation/fault clears the request; held run alone
      // can never rearm playback after STOP.
      if(cancelling) pending_start<=0;
      else if(run && !run_d) pending_start<=1;
      sixteenth_ce<=0;loop_boundary<=0;
      if(running) phase<=phase_sum[31:0];
      if(cancelling && !cancel_seen) begin
        running<=0;phase<=0;loop_tick<=0;state<=RELEASE;
      end else if(overrun) halt_fault(8'd2,{19'd0,loop_tick,slot});
      else if(read_timeout) halt_fault(8'd3,{26'd0,slot});
      else if(deadline) begin
        sixteenth_ce<=1;heartbeat_toggle<=~heartbeat_toggle;
        slot<=0;pass<=0;
        if(loop_tick==127) begin
          loop_tick<=0;
          if(bpm_value<60 || bpm_value>180) halt_fault(8'd1,{16'd0,bpm_value});
          else begin active_bpm<=bpm_value;phase_step<=bpm_step(bpm_value);state<=BOUND_OFF;end
        end else begin loop_tick<=loop_tick+1'b1;state<=REQUEST;end
      end else begin
        case(state)
          IDLE: if(run && (!run_d || pending_start) && !cancelling) begin
            pending_start<=0;
            if(bpm_value<60 || bpm_value>180) halt_fault(8'd1,{16'd0,bpm_value});
            else begin
              running<=1;active_bpm<=bpm_value;phase_step<=bpm_step(bpm_value);phase<=0;
              loop_tick<=0;sixteenth_ce<=1;slot<=0;pass<=0;state<=REQUEST;
              heartbeat_toggle<=~heartbeat_toggle;
            end
          end
          REQUEST: begin state<=RESPONSE;read_wait<=0;end
          RESPONSE: if(read_valid) begin
            heartbeat_toggle<=~heartbeat_toggle;
            if(match_event) begin
              pending_data<=read_data;
              if(pass==0 && derived_off) begin
                pending_data[2:0]<=3'd1;pending_data[11:5]<=end_tick[6:0];pending_data[18:12]<=0;
              end
              state<=SEND;
            end else next_slot;
          end else read_wait<=read_wait+1'b1;
          SEND: if(event_valid && event_ready) next_slot;
          WAIT_TICK: begin end
          BOUND_OFF: if(event_valid && event_ready) state<=BOUND_MARK;
          BOUND_MARK: if(event_valid && event_ready) begin
            loop_boundary<=1;state<=SWAP_WAIT;
          end
          // Store samples loop_boundary during this full guard cycle; its
          // swap cancels reads on that edge. REQUEST follows the swap edge.
          SWAP_WAIT: state<=REQUEST;
          RELEASE: if(event_valid && event_ready) begin state<=IDLE;heartbeat_toggle<=~heartbeat_toggle;end
          default: halt_fault(8'd4,{28'd0,state});
        endcase
      end
    end
  end
endmodule
