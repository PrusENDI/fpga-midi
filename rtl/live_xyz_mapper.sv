// LIVE-only XYZ mapper. X selects the note zone, Y participates only in the
// motion-rate stability test, and Z owns the hysteretic note state and
// pressure target. Discrete events use a two-entry safety queue; pressure is
// a latest-value channel and may replace a stalled point.
module live_xyz_mapper #(
    // MGC3130 reports can jump several thousand counts between adjacent
    // frames even when the hand remains over one X note zone.  Keep the
    // rate gate wide enough for that normal motion; the zone check below
    // still prevents a pitch change until the X zone has settled.
    parameter integer XY_STABLE_DELTA = 512,
    parameter integer XY_STABLE_FRAMES = 3,
    // Use half of the previous trigger height.  The calibrated pressure band
    // remains 4096..36864, while release keeps a small 2048-count buffer.
    parameter integer Z_TOUCH_MIN = 4096,
    parameter integer Z_ON = 18432,
    parameter integer Z_OFF = 20480
) (
    input wire clk, input wire rst_n,
    input wire enable, input wire flush,
    input wire report_valid, input wire xyz_valid, input wire report_error,
    input wire [15:0] x_position, input wire [15:0] y_position,
    input wire [15:0] z_position, input wire [1:0] selected_track,
    output wire event_valid, input wire event_ready, output wire [63:0] event_data,
    output wire modulation_valid, input wire modulation_ready,
    output wire [63:0] modulation_data,
    output wire idle, output reg overflow
);
    import performance_event_pkg::*;

    localparam [6:0] STABLE_LIMIT = (XY_STABLE_FRAMES < 1) ? 7'd1 : XY_STABLE_FRAMES[6:0];
    reg [63:0] event_q0, event_q1;
    reg [1:0] event_count;
    reg mod_valid_r;
    reg [63:0] mod_data_r;
    reg note_active;
    reg [2:0] active_zone, candidate_zone;
    reg [6:0] stable_count;
    reg [15:0] previous_x, previous_y;
    reg have_previous;

    wire good_report = enable && report_valid && xyz_valid && !report_error;
    wire event_pop = event_valid && event_ready;
    wire modulation_pop = modulation_valid && modulation_ready;
    assign event_valid = event_count != 0;
    assign event_data = event_q0;
    assign modulation_valid = mod_valid_r;
    assign modulation_data = mod_data_r;
    assign idle = (event_count == 0) && !mod_valid_r && !note_active;

    function automatic [2:0] x_zone(input [15:0] value);
      x_zone = value[15:13];
    endfunction
    function automatic [16:0] abs_delta(input [15:0] a, input [15:0] b);
      begin abs_delta = (a >= b) ? (a - b) : (b - a); end
    endfunction
    function automatic [7:0] pressure_value(input [15:0] value);
      integer scaled;
      begin
        if (value >= Z_ON) pressure_value = 8'd0;
        else if (value <= Z_TOUCH_MIN) pressure_value = 8'd255;
        else begin
          scaled = ((value - Z_TOUCH_MIN) * 255) / (Z_ON - Z_TOUCH_MIN);
          if (scaled > 255) scaled = 255;
          pressure_value = 8'd255 - scaled[7:0];
        end
      end
    endfunction
    function automatic [6:0] zone_note(input [2:0] zone);
      begin case (zone)
        // LIVE spans one C-major octave from C4 through C5.  The previous
        // table selected C3..C4, which made the board sound an octave low.
        3'd0: zone_note = 7'd60;
        3'd1: zone_note = 7'd62;
        3'd2: zone_note = 7'd64;
        3'd3: zone_note = 7'd65;
        3'd4: zone_note = 7'd67;
        3'd5: zone_note = 7'd69;
        3'd6: zone_note = 7'd71;
        default: zone_note = 7'd72;
      endcase end
    endfunction
    function automatic [63:0] make_event(input [2:0] kind, input [6:0] note,
                                          input [7:0] level);
      reg [63:0] value;
      begin
        value = 64'd0;
        value[2:0] = kind;
        value[4:3] = selected_track;
        value[25:19] = note;
        value[33:26] = level;
        value[49:42] = level;
        value[57:50] = level;
        make_event = value;
      end
    endfunction

    task automatic enqueue_event(input [63:0] value);
      reg [63:0] kill_value;
      begin
        kill_value = make_event(EVENT_ALL_NOTES_OFF, 7'd0, 8'd0);
        if (event_count == 0) begin
          event_q0 <= value;
          event_count <= 1;
        end else if (event_count == 1) begin
          if (event_pop) begin
            event_q0 <= event_q1;
            event_q1 <= value;
          end else begin
            event_q1 <= value;
          end
          event_count <= 2;
        end else if (event_pop) begin
          event_q0 <= event_q1;
          event_q1 <= value;
          event_count <= 2;
        end else begin
          event_q0 <= kill_value;
          event_q1 <= value;
          event_count <= 2;
          overflow <= 1'b1;
        end
      end
    endtask

    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        event_q0 <= 0; event_q1 <= 0; event_count <= 0;
        mod_valid_r <= 0; mod_data_r <= 0; overflow <= 0;
        note_active <= 0; active_zone <= 0; candidate_zone <= 0;
        stable_count <= 0; previous_x <= 0; previous_y <= 0;
        have_previous <= 0;
      end else begin
        if (event_pop) begin
          if (event_count == 2) begin event_q0 <= event_q1; event_count <= 1; end
          else event_count <= 0;
        end
        if (modulation_pop) mod_valid_r <= 0;
        if (flush || !enable) begin
          event_q0 <= 0; event_q1 <= 0; event_count <= 0;
          mod_valid_r <= 0; note_active <= 0; active_zone <= 0;
          candidate_zone <= 0; stable_count <= 0; have_previous <= 0;
          overflow <= 0;
        end else if (good_report) begin
          if (!have_previous) begin
            previous_x <= x_position; previous_y <= y_position;
            candidate_zone <= x_zone(x_position); stable_count <= 1;
            have_previous <= 1;
          end else if ((abs_delta(x_position, previous_x) <= XY_STABLE_DELTA) &&
                       (abs_delta(y_position, previous_y) <= XY_STABLE_DELTA)) begin
            previous_x <= x_position; previous_y <= y_position;
            if (candidate_zone == x_zone(x_position)) begin
              if (stable_count < STABLE_LIMIT) stable_count <= stable_count + 1'b1;
            end else begin
              candidate_zone <= x_zone(x_position); stable_count <= 1;
            end
          end else begin
            previous_x <= x_position; previous_y <= y_position;
            candidate_zone <= x_zone(x_position); stable_count <= 1;
          end

          if (!note_active && z_position <= Z_ON && stable_count >= STABLE_LIMIT-1) begin
            enqueue_event(make_event(EVENT_NOTE_ON, zone_note(candidate_zone), pressure_value(z_position)));
            note_active <= 1; active_zone <= candidate_zone;
          end else if (note_active && z_position >= Z_OFF) begin
            enqueue_event(make_event(EVENT_NOTE_OFF, zone_note(active_zone), 8'd0));
            note_active <= 0;
          end else if (note_active && stable_count >= STABLE_LIMIT-1 && candidate_zone != active_zone) begin
            enqueue_event(make_event(EVENT_NOTE_REVOICE, zone_note(candidate_zone), pressure_value(z_position)));
            active_zone <= candidate_zone;
          end

          if (note_active && z_position <= Z_ON) begin
            mod_valid_r <= 1;
            mod_data_r <= make_event(EVENT_CONTROL_POINT, zone_note(active_zone), pressure_value(z_position));
          end
        end
      end
    end
endmodule
