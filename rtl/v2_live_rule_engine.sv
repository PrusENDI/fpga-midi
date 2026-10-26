// Independent V2 LIVE rules.  This block emits only the frozen 96-bit event
// contract; it has no connection to the legacy PC EventTable path.
module v2_live_rule_engine #(
  parameter integer TRACK = 0,
  parameter integer NOTE_MIN = 24,
  parameter integer NOTE_MAX = 96,
  parameter integer X_EDGE = 2048,
  parameter integer HYSTERESIS = 1024,
  parameter integer MIN_EVENT_TICKS = 4,
  parameter integer GATE_TOUCH = 0
) (
  input  logic clk, input logic rst_n,
  input  logic frame_in_valid, input logic frame_valid,
  input  logic frame_degraded, input logic frame_gap, input logic rebased,
  input  logic left_edge,
  input  logic [15:0] x, input logic [15:0] y, input logic [15:0] z,
  input  logic touch, input logic bow, input logic [31:0] tick,
  input logic [7:0] velocity_in, input logic [15:0] brightness_in,
  input logic [15:0] gain_in,
  output logic event_valid, input logic event_ready,
  output logic [95:0] event_data,
  output logic [3:0] event_type, output logic [7:0] event_note,
  output logic [7:0] event_velocity,
  output logic [15:0] event_count,
  output logic [7:0] fault_code,
  output logic left_edge_armed, output logic gate_state,
  output logic active, output logic [7:0] active_note
);
  import v2_contract_pkg::*;

  logic [15:0] prev_x, prev_z;
  logic prev_valid, have_last_event;
  logic [31:0] last_event_tick;
  logic [15:0] event_seq;
  logic candidate_valid;
  logic [3:0] candidate_type;
  logic [7:0] candidate_note, candidate_velocity, candidate_flags;
  logic [15:0] candidate_timbre;
  logic candidate_due, bad_frame, gate_now, edge_cross;
  logic edge_pending, arm_now;
  logic note_change_ok;

  function automatic [7:0] map_note(input logic [15:0] value);
    integer n;
    begin
      n = NOTE_MIN + (value * (NOTE_MAX-NOTE_MIN)) / 65535;
      if (n < 0) n=0; else if (n > 127) n=127;
      map_note = n[7:0];
    end
  endfunction

  always_comb begin
    gate_now = GATE_TOUCH ? touch : bow;
    bad_frame = !frame_valid || frame_degraded || frame_gap || rebased;
    candidate_note = map_note(y);
    candidate_velocity = velocity_in;
    candidate_timbre = brightness_in;
    candidate_type = V2_EV_CONTROL;
    candidate_flags = V2_FLAG_Z | (touch ? V2_FLAG_TOUCH : V2_FLAG_BOW);
    candidate_valid = 1'b0;
    candidate_due = !have_last_event || ((tick - last_event_tick) >= MIN_EVENT_TICKS);
    edge_cross = prev_valid && (((prev_x <= X_EDGE) && (x > X_EDGE)) ||
                                ((prev_x > X_EDGE) && (x <= X_EDGE)));
    arm_now = left_edge_armed || (edge_pending && x > X_EDGE && (!prev_valid || x >= prev_x));
    note_change_ok = 1'b1;
    if (active && (candidate_note != active_note)) begin
      integer boundary;
      boundary = ((active_note - NOTE_MIN + ((candidate_note > active_note) ? 1 : 0)) * 65535) /
                 ((NOTE_MAX > NOTE_MIN) ? (NOTE_MAX-NOTE_MIN) : 1);
      if (candidate_note > active_note) note_change_ok = (y >= boundary + HYSTERESIS);
      else note_change_ok = (y + HYSTERESIS <= boundary);
    end
    if (frame_in_valid && !bad_frame) begin
      if (!active && arm_now && gate_now && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_NOTE_ON;
        candidate_flags = touch ? V2_FLAG_TOUCH : V2_FLAG_BOW;
      end else if (active && !gate_now && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_NOTE_OFF;
        candidate_note=active_note; candidate_flags=0;
      end else if (active && gate_now && (candidate_note != active_note) && note_change_ok && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_REVOICE;
        candidate_flags = touch ? V2_FLAG_TOUCH : V2_FLAG_BOW;
      end else if (active && gate_now && edge_cross && (candidate_note == active_note) && candidate_due) begin
        candidate_valid=1'b1; candidate_type=V2_EV_REVOICE;
        candidate_flags = (touch ? V2_FLAG_TOUCH : V2_FLAG_BOW) | V2_FLAG_REBASED;
      end else if (prev_valid && (z != prev_z)) begin
        // Depth is expression; pure Z never creates a note event.
        candidate_valid=1'b1; candidate_type=V2_EV_CONTROL;
      end
    end
  end

  always_comb begin
    event_type = event_data[94:91]; event_note = event_data[71:64];
    event_velocity = event_data[63:56];
  end

  always_ff @(posedge clk or negedge rst_n) begin : live_state
    logic [95:0] packed_event;
    if (!rst_n) begin
      event_valid<=0; event_data<=0; event_count<=0; fault_code<=0;
      left_edge_armed<=0; edge_pending<=0; gate_state<=0; active<=0; active_note<=0;
      prev_x<=0; prev_z<=0; prev_valid<=0; have_last_event<=0;
      last_event_tick<=0; event_seq<=0;
    end else begin
      if (event_valid && event_ready) event_valid <= 1'b0;
      gate_state <= gate_now;
      // A stalled output freezes the rule state.  This keeps the pending
      // event and its metadata stable until the ready handshake.
      if (frame_in_valid && !bad_frame && !(event_valid && !event_ready)) begin
        // The edge sample only starts arming; a final rightward sample commits it.
        if (!left_edge_armed && !edge_pending && (left_edge || x <= X_EDGE)) begin
          if (!prev_valid || x >= prev_x) edge_pending <= 1'b1;
          else fault_code <= V2_FAULT_REVERSE;
        end else if (!left_edge_armed && edge_pending) begin
          if (x > X_EDGE && (!prev_valid || x >= prev_x)) begin
            left_edge_armed <= 1'b1;
            edge_pending <= 1'b0;
          end else if (x < prev_x) begin
            edge_pending <= 1'b0;
            fault_code <= V2_FAULT_REVERSE;
          end
        end
        prev_x <= x; prev_z <= z; prev_valid <= 1'b1;
      end else if (frame_in_valid && bad_frame) begin
        fault_code <= V2_FAULT_INVALID;
      end
      if (candidate_valid && !(event_valid && !event_ready)) begin
        packed_event = 96'd0;
        packed_event[94:91] = candidate_type;
        packed_event[90:88] = TRACK[2:0];
        packed_event[87:80] = tick[7:0];
        packed_event[79:72] = 8'd0;
        packed_event[71:64] = candidate_note;
        packed_event[63:56] = candidate_velocity;
        packed_event[55:40] = 16'd0;
        packed_event[39:24] = candidate_timbre;
        packed_event[23:16] = candidate_flags;
        packed_event[15:0] = event_seq;
        if (!event_valid || event_ready) begin
          event_data <= packed_event; event_valid <= 1'b1;
          event_count <= event_count + 1'b1; event_seq <= event_seq + 1'b1;
          have_last_event <= 1'b1; last_event_tick <= tick;
          if (candidate_type == V2_EV_NOTE_ON) begin active<=1'b1; active_note<=candidate_note; end
          else if (candidate_type == V2_EV_NOTE_OFF) active<=1'b0;
          else if (candidate_type == V2_EV_REVOICE) begin active<=1'b1; active_note<=candidate_note; end
        end
      end
    end
  end
endmodule
