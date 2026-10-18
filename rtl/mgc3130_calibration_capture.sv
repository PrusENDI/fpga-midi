// Temporary raw MGC3130 report capture for calibration.  This module sits
// immediately after mgc3130_reader and deliberately does not apply any Loop
// input filtering or note mapping.
module mgc3130_calibration_capture #(
    parameter integer DEPTH = 4,
    parameter [31:0] BUILD_TAG = 32'h43414C31
) (
    input wire clk, input wire rst_n, input wire mgc_ready,
    input wire report_valid, input wire xyz_valid, input wire report_error,
    input wire touch_valid, input wire [31:0] touch_info,
    input wire [15:0] x_position, input wire [15:0] y_position,
    input wire [15:0] z_position, input wire [7:0] gesture_code,
    input wire [3:0] error_code, input wire reader_busy,
    output wire tx_valid, input wire tx_ready, output wire [7:0] tx_data,
    output reg capture_overflow, output reg [15:0] report_sequence
);
    localparam integer FRAME_BYTES = 32;
    localparam [7:0] FRAME_VERSION = 8'd1;
    localparam [7:0] TYPE_METADATA = 8'd0;
    localparam [7:0] TYPE_REPORT = 8'd1;
    localparam integer PTR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
    localparam [PTR_W-1:0] PTR_INC = {{(PTR_W-1){1'b0}}, 1'b1};
    localparam [PTR_W-1:0] PTR_LAST = DEPTH - 1;
    localparam [PTR_W-1:0] PTR_ZERO = {PTR_W{1'b0}};
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    localparam [COUNT_W-1:0] COUNT_INC = {{(COUNT_W-1){1'b0}}, 1'b1};

    reg [15:0] fifo_seq [0:DEPTH-1];
    reg [31:0] fifo_timestamp [0:DEPTH-1];
    reg [7:0] fifo_flags [0:DEPTH-1];
    reg [15:0] fifo_x [0:DEPTH-1], fifo_y [0:DEPTH-1], fifo_z [0:DEPTH-1];
    reg [7:0] fifo_gesture [0:DEPTH-1], fifo_error [0:DEPTH-1];
    reg [31:0] fifo_touch [0:DEPTH-1];
    reg [PTR_W-1:0] wr_ptr, rd_ptr;
    reg [PTR_W:0] fifo_count;
    reg [31:0] timestamp;
    reg metadata_pending, metadata_sent, frame_active, frame_type;
    reg [5:0] frame_index;
    reg [15:0] active_seq;
    reg [31:0] active_timestamp, active_touch;
    reg [7:0] active_flags, active_gesture, active_error;
    reg [15:0] active_x, active_y, active_z;
    integer i;

    function automatic [7:0] crc_step(input [7:0] prior, input [7:0] value);
        integer k; reg [7:0] c;
        begin
            c = prior ^ value;
            for (k = 0; k < 8; k = k + 1)
                c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc_step = c;
        end
    endfunction

    function automatic [7:0] body_byte(input integer n);
        begin
            case (n)
                2: body_byte = FRAME_VERSION;
                3: body_byte = frame_type ? TYPE_REPORT : TYPE_METADATA;
                4: body_byte = FRAME_BYTES;
                5: body_byte = active_seq[7:0]; 6: body_byte = active_seq[15:8];
                7: body_byte = active_timestamp[7:0]; 8: body_byte = active_timestamp[15:8];
                9: body_byte = active_timestamp[23:16]; 10: body_byte = active_timestamp[31:24];
                11: body_byte = active_flags;
                12: body_byte = active_x[7:0]; 13: body_byte = active_x[15:8];
                14: body_byte = active_y[7:0]; 15: body_byte = active_y[15:8];
                16: body_byte = active_z[7:0]; 17: body_byte = active_z[15:8];
                18: body_byte = active_gesture; 19: body_byte = active_error;
                20: body_byte = active_touch[7:0]; 21: body_byte = active_touch[15:8];
                22: body_byte = active_touch[23:16]; 23: body_byte = active_touch[31:24];
                24: body_byte = BUILD_TAG[7:0]; 25: body_byte = BUILD_TAG[15:8];
                26: body_byte = BUILD_TAG[23:16]; 27: body_byte = BUILD_TAG[31:24];
                default: body_byte = 8'h00;
            endcase
        end
    endfunction

    function automatic [7:0] frame_byte(input integer n);
        integer k; reg [7:0] c;
        begin
            if (n == 0) frame_byte = 8'hA5;
            else if (n == 1) frame_byte = 8'h5A;
            else if (n < 28) frame_byte = body_byte(n);
            else if (n < 31) frame_byte = 8'h00;
            else begin
                c = 8'h00;
                for (k = 2; k <= 30; k = k + 1) c = crc_step(c, body_byte(k));
                frame_byte = c;
            end
        end
    endfunction

    assign tx_valid = frame_active;
    assign tx_data = frame_byte(frame_index);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0; rd_ptr <= 0; fifo_count <= 0; timestamp <= 0;
            metadata_pending <= 0; metadata_sent <= 0; frame_active <= 0; frame_type <= 0; frame_index <= 0;
            active_seq <= 0; active_timestamp <= 0; active_touch <= 0;
            active_flags <= 0; active_gesture <= 0; active_error <= 0;
            active_x <= 0; active_y <= 0; active_z <= 0;
            capture_overflow <= 0; report_sequence <= 0;
        end else begin
            timestamp <= timestamp + 1'b1;
            if (mgc_ready && !metadata_sent) metadata_pending <= 1'b1;

            if (report_valid) begin
                report_sequence <= report_sequence + 1'b1;
                if (fifo_count < DEPTH) begin
                    fifo_seq[wr_ptr] <= report_sequence;
                    fifo_timestamp[wr_ptr] <= timestamp;
                    fifo_flags[wr_ptr] <= {1'b0, capture_overflow, reader_busy, mgc_ready,
                        touch_valid, report_error, xyz_valid, 1'b1};
                    fifo_x[wr_ptr] <= x_position; fifo_y[wr_ptr] <= y_position;
                    fifo_z[wr_ptr] <= z_position; fifo_gesture[wr_ptr] <= gesture_code;
                    fifo_error[wr_ptr] <= {4'd0, error_code}; fifo_touch[wr_ptr] <= touch_info;
                    wr_ptr <= (wr_ptr == PTR_LAST) ? PTR_ZERO : wr_ptr + PTR_INC;
                    fifo_count <= fifo_count + COUNT_INC;
                end else capture_overflow <= 1'b1;
            end

            if (!frame_active) begin
                if (metadata_pending) begin
                    frame_active <= 1'b1; frame_type <= 1'b0; frame_index <= 0;
                    metadata_pending <= 1'b0; metadata_sent <= 1'b1;
                    active_seq <= 0; active_timestamp <= timestamp;
                    active_flags <= {1'b0, capture_overflow, reader_busy, mgc_ready, 4'd0};
                    active_x <= 0; active_y <= 0; active_z <= 0; active_gesture <= 0;
                    active_error <= 0; active_touch <= 0;
                end else if (fifo_count != 0) begin
                    frame_active <= 1'b1; frame_type <= 1'b1; frame_index <= 0;
                    active_seq <= fifo_seq[rd_ptr]; active_timestamp <= fifo_timestamp[rd_ptr];
                    active_flags <= fifo_flags[rd_ptr]; active_x <= fifo_x[rd_ptr];
                    active_y <= fifo_y[rd_ptr]; active_z <= fifo_z[rd_ptr];
                    active_gesture <= fifo_gesture[rd_ptr]; active_error <= fifo_error[rd_ptr];
                    active_touch <= fifo_touch[rd_ptr];
                    rd_ptr <= (rd_ptr == PTR_LAST) ? PTR_ZERO : rd_ptr + PTR_INC;
                    fifo_count <= fifo_count - COUNT_INC;
                end
            end else if (tx_valid && tx_ready) begin
                if (frame_index == FRAME_BYTES-1) begin
                    frame_active <= 1'b0; frame_index <= 0;
                end else frame_index <= frame_index + 1'b1;
            end
        end
    end
endmodule
