// Capture one complete MGC3130 report in the 50 MHz FPGA clock domain.
// Legacy ports and pulse semantics are preserved; v2_* outputs expose a signed,
// sequenced raw frame for the V2 calibration boundary.
module mgc3130_input_latch (
    input wire clk, input wire rst_n,
    input wire report_valid, input wire xyz_valid, input wire report_error,
    input wire [15:0] x_position, input wire [15:0] y_position,
    input wire [15:0] z_position, input wire [7:0] gesture_code,
    output reg input_valid, output reg xyz_valid_latched,
    output reg [15:0] x_latched, output reg [15:0] y_latched,
    output reg [15:0] z_latched, output reg [7:0] gesture_latched,
    input wire [31:0] touch_info, input wire touch_valid,
    output reg report_valid_latched, output reg report_error_latched,
    output reg touch_valid_latched, output reg [31:0] touch_info_latched,
    output reg [15:0] v2_sequence, output reg [31:0] v2_timestamp_ticks,
    output reg signed [15:0] v2_raw_x, output reg signed [15:0] v2_raw_y,
    output reg signed [15:0] v2_raw_z, output reg v2_frame_valid,
    output reg v2_gap, output reg v2_saturated, output reg [7:0] v2_calibration_epoch,
    output reg v2_touch, output reg v2_presence
);
    reg [15:0] sequence_counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_valid <= 1'b0; xyz_valid_latched <= 1'b0;
            x_latched <= 16'd0; y_latched <= 16'd0; z_latched <= 16'd0; gesture_latched <= 8'd0;
            report_valid_latched <= 0; report_error_latched <= 0;
            touch_valid_latched <= 0; touch_info_latched <= 0;
            v2_sequence <= 0; v2_timestamp_ticks <= 0; sequence_counter <= 0;
            v2_raw_x <= 0; v2_raw_y <= 0; v2_raw_z <= 0; v2_frame_valid <= 0;
            v2_gap <= 0; v2_saturated <= 0; v2_calibration_epoch <= 0; v2_touch <= 0; v2_presence <= 0;
        end else begin
            v2_timestamp_ticks <= v2_timestamp_ticks + 1'b1;
            input_valid <= 1'b0; xyz_valid_latched <= 1'b0;
            report_valid_latched <= report_valid; report_error_latched <= report_valid && report_error;
            touch_valid_latched <= 0; v2_frame_valid <= 0; v2_gap <= 0; v2_saturated <= 0; v2_touch <= 0;
            if (report_valid) begin
                sequence_counter <= sequence_counter + 1'b1;
                v2_sequence <= sequence_counter;
                v2_raw_x <= x_position; v2_raw_y <= y_position; v2_raw_z <= z_position;
                v2_frame_valid <= xyz_valid && !report_error;
                v2_touch <= touch_valid && !report_error; v2_presence <= xyz_valid && !report_error;
                // The reader exposes report_error as the loss boundary; no raw value is guessed.
                v2_gap <= report_error;
                v2_saturated <= (x_position == 16'h7fff) || (x_position == 16'h8000) ||
                                (y_position == 16'h7fff) || (y_position == 16'h8000) ||
                                (z_position == 16'h7fff) || (z_position == 16'h8000);
                touch_valid_latched <= touch_valid && !report_error; touch_info_latched <= (touch_valid && !report_error) ? touch_info : 32'd0;
            end
            if (report_valid && xyz_valid && !report_error) begin
                x_latched <= x_position; y_latched <= y_position; z_latched <= z_position; gesture_latched <= gesture_code;
                input_valid <= 1'b1; xyz_valid_latched <= 1'b1;
            end
        end
    end
endmodule
