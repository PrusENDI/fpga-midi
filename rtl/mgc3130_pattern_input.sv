// Fixed-calibration MGC3130 coordinate to melody-event front end.
// X is phrase time, Y is quantized pitch, and Z is velocity.
module mgc3130_pattern_input #(
    parameter [15:0] X_START = 16'h1000,
    parameter [15:0] X_END = 16'hF000,
    parameter [15:0] Y_MIN = 16'h1000,
    parameter [15:0] Y_MAX = 16'hF000,
    parameter integer START_CONFIRM = 2,
    parameter integer END_CONFIRM = 2,
    parameter integer CELL_CONFIRM = 2,
    parameter integer NOTE_CONFIRM = 6,
    parameter integer FIRST_NOTE_CONFIRM = 1,
    parameter [15:0] FIRST_NOTE_X_GATE = 16'h1000,
    parameter [15:0] START_MAX = 16'h3000,
    parameter [15:0] END_MIN = 16'hD000,
    parameter integer TIMEOUT_CYCLES = 5_000_000
) (
    input wire clk,
    input wire rst_n,
    input wire report_valid,
    input wire xyz_valid,
    input wire report_error,
    input wire [15:0] x_position,
    input wire [15:0] y_position,
    input wire [15:0] z_position,
    output reg recording,
    output reg pattern_commit,
    output reg cell_event,
    output reg note_on,
    output reg note_off,
    output reg expression_valid,
    output reg [4:0] time_cell,
    output reg [6:0] note_number,
    output reg [7:0] velocity
);
    // Fewer, wider time cells make phrase timing more robust on the roughly
    // 10 cm sensing surface.
    localparam integer CELL_COUNT = 8;
    localparam integer NOTE_COUNT = 9;
    localparam integer NOTE_BASE = 48; // C major diatonic roots C..C

    reg rearm_ready;
    reg [3:0] start_count, end_count;
    reg [3:0] cell_count, note_count;
    reg [4:0] cell_candidate;
    reg [6:0] note_candidate;
    reg note_started;
    reg [15:0] z_smooth;
    reg [31:0] timeout_count;
    reg note_on_pending, note_off_pending;

    function [4:0] map_cell;
        input [15:0] value;
        integer scaled;
        begin
            if (value <= X_START)
                map_cell = 5'd0;
            else if (value >= X_END)
                map_cell = 5'd31;
            else begin
                scaled = ((value - X_START) * CELL_COUNT) /
                         (X_END - X_START);
                if (scaled > 31) scaled = 31;
                map_cell = scaled[4:0];
            end
        end
    endfunction

    function [6:0] map_note;
        input [15:0] value;
        integer scaled;
        begin
            // Keep a deliberate center band around Y=0x8000 on middle C.
            // Four diatonic notes are below it and four above it.
            // Equal-width C-major diatonic zones, with the center of the
            // sensing range landing on middle C and no semitone choices.
            if (value <= Y_MIN)
                scaled = 0;
            else if (value >= Y_MAX)
                scaled = 12;
            else
                scaled = ((value - Y_MIN) * 13) / (Y_MAX - Y_MIN);
            if (scaled > 12) scaled = 12;
            case ((scaled * 8) / 13)
                0: map_note = 7'd48; 1: map_note = 7'd50;
                2: map_note = 7'd52; 3: map_note = 7'd53;
                4: map_note = 7'd55; 5: map_note = 7'd57;
                6: map_note = 7'd59; default: map_note = 7'd60;
            endcase
        end
    endfunction

    function [7:0] map_velocity;
        input [15:0] value;
        integer scaled;
        begin
            // Keep a clearly audible floor while preserving the calibrated
            // Z response.  This avoids silent notes when Z briefly reaches 0.
            scaled = 64 + ((value * 191) / 65535);
            if (scaled > 255) scaled = 255;
            map_velocity = scaled[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recording <= 1'b0;
            pattern_commit <= 1'b0;
            cell_event <= 1'b0;
            note_on <= 1'b0;
            note_off <= 1'b0;
            expression_valid <= 1'b0;
            time_cell <= 5'd0;
            note_number <= 7'd48;
            velocity <= 8'd0;
            z_smooth <= 16'd0;
            // Start is armed after reset; after a phrase, the hand must
            // reach the right side once before another left-edge start.
            rearm_ready <= 1'b1;
            start_count <= 0; end_count <= 0;
            cell_count <= 0; note_count <= 0;
            cell_candidate <= 0; note_candidate <= 7'd48;
            note_started <= 1'b0;
            timeout_count <= 0;
            note_on_pending <= 1'b0;
            note_off_pending <= 1'b0;
        end else begin
            pattern_commit <= 1'b0;
            cell_event <= 1'b0;
            note_on <= note_on_pending;
            note_off <= note_off_pending;
            note_on_pending <= 1'b0;
            note_off_pending <= 1'b0;
            expression_valid <= 1'b0;

            if (recording && (timeout_count < TIMEOUT_CYCLES))
                timeout_count <= timeout_count + 1'b1;

            if (recording && (timeout_count >= TIMEOUT_CYCLES)) begin
                note_off_pending <= 1'b1;
                recording <= 1'b0;
                pattern_commit <= 1'b0;
                rearm_ready <= 1'b1;
                start_count <= 0; end_count <= 0;
                timeout_count <= 0;
            end

            if (report_valid && xyz_valid && !report_error) begin
                timeout_count <= 0;

                if (!recording) begin
                    if (x_position >= END_MIN)
                        rearm_ready <= 1'b1;
                    if (x_position > START_MAX)
                        start_count <= 0;
                    if (x_position <= START_MAX && rearm_ready) begin
                        // A valid left-edge report is sufficient to arm a
                        // phrase. Requiring a second report here made the
                        // start edge unnecessarily fragile when reports were
                        // sparse or the sensor briefly flagged invalid data.
                        recording <= 1'b1;
                        rearm_ready <= 1'b0;
                        start_count <= 0;
                        end_count <= 0;
                        cell_count <= 0;
                        note_count <= 0;
                        time_cell <= 0;
                        note_number <= map_note(y_position);
                        note_candidate <= map_note(y_position);
                        note_count <= 1;
                        note_started <= 1'b0;
                        z_smooth <= z_position;
                        velocity <= map_velocity(z_position);
                    end else if (x_position > START_MAX) begin
                        rearm_ready <= 1'b0;
                    end
                end else begin
                    if (x_position >= END_MIN) begin
                        if (end_count < END_CONFIRM)
                            end_count <= end_count + 1'b1;
                        if (end_count >= END_CONFIRM - 1) begin
                            if (note_started)
                                note_off_pending <= 1'b1;
                            recording <= 1'b0;
                            pattern_commit <= 1'b1;
                            rearm_ready <= 1'b1;
                            end_count <= 0;
                            timeout_count <= 0;
                        end
                    end else begin
                        end_count <= 0;
                        if (z_position >= z_smooth)
                            z_smooth <= z_smooth + ((z_position - z_smooth) >> 2);
                        else
                            z_smooth <= z_smooth - ((z_smooth - z_position) >> 2);
                        velocity <= map_velocity(z_smooth);
                        expression_valid <= 1'b1;

                        if (!note_started && (x_position >= FIRST_NOTE_X_GATE)) begin
                            if (note_candidate == map_note(y_position)) begin
                                if (note_count < NOTE_CONFIRM)
                                    note_count <= note_count + 1'b1;
                            end else begin
                                note_candidate <= map_note(y_position);
                                note_count <= 1;
                            end
                            if ((note_candidate == map_note(y_position)) &&
                                (note_count >= FIRST_NOTE_CONFIRM - 1)) begin
                                note_number <= map_note(y_position);
                                note_started <= 1'b1;
                                note_count <= 0;
                                note_on_pending <= 1'b1;
                            end
                        end

                        if (note_started && (map_cell(x_position) != time_cell)) begin
                            if (cell_candidate == map_cell(x_position)) begin
                                if (cell_count < CELL_CONFIRM)
                                    cell_count <= cell_count + 1'b1;
                            end else begin
                                cell_candidate <= map_cell(x_position);
                                cell_count <= 1;
                            end
                            if ((cell_candidate == map_cell(x_position)) &&
                                (cell_count >= CELL_CONFIRM - 1)) begin
                                time_cell <= map_cell(x_position);
                                cell_event <= 1'b1;
                                note_off_pending <= 1'b1;
                                note_on_pending <= 1'b1;
                                cell_count <= 0;
                            end
                        end else begin
                            cell_candidate <= time_cell;
                            cell_count <= 0;
                        end

                        if (note_started && (map_note(y_position) != note_number)) begin
                            if (note_candidate == map_note(y_position)) begin
                                if (note_count < NOTE_CONFIRM)
                                    note_count <= note_count + 1'b1;
                            end else begin
                                note_candidate <= map_note(y_position);
                                note_count <= 1;
                            end
                            if ((note_candidate == map_note(y_position)) &&
                                (note_count >= NOTE_CONFIRM - 1)) begin
                                note_off_pending <= 1'b1;
                                note_number <= map_note(y_position);
                                note_on_pending <= 1'b1;
                                note_count <= 0;
                            end
                        end else begin
                            note_candidate <= note_number;
                            note_count <= 0;
                        end
                    end
                end
            end
        end
    end
endmodule
