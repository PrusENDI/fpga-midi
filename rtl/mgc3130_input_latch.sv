// Capture one complete MGC3130 report in the 50 MHz FPGA clock domain.
module mgc3130_input_latch (
    input wire clk, input wire rst_n,
    input wire report_valid, input wire xyz_valid, input wire report_error,
    input wire [15:0] x_position, input wire [15:0] y_position,
    input wire [15:0] z_position, input wire [7:0] gesture_code,
    output reg input_valid, output reg xyz_valid_latched,
    output reg [15:0] x_latched, output reg [15:0] y_latched,
    output reg [15:0] z_latched, output reg [7:0] gesture_latched,
    input wire [31:0] touch_info, input wire touch_valid,
    // Report pulse includes touch-only, invalid-position and error reports.
    // Consumers must inspect report_error_latched and individual valid flags.
    // Legacy input_valid remains a successful XYZ-only pulse.
    output reg report_valid_latched, output reg report_error_latched,
    output reg touch_valid_latched, output reg [31:0] touch_info_latched
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_valid <= 1'b0;
            xyz_valid_latched <= 1'b0;
            x_latched <= 16'd0; y_latched <= 16'd0; z_latched <= 16'd0;
            gesture_latched <= 8'd0;
            report_valid_latched <= 0; report_error_latched <= 0;
            touch_valid_latched <= 0; touch_info_latched <= 0;
        end else begin
            input_valid <= 1'b0;
            xyz_valid_latched <= 1'b0;
            report_valid_latched <= report_valid;
            report_error_latched <= report_valid && report_error;
            touch_valid_latched <= 0;
            if (report_valid) begin
                touch_valid_latched <= touch_valid && !report_error;
                touch_info_latched <= (touch_valid && !report_error) ? touch_info : 32'd0;
            end
            if (report_valid && xyz_valid && !report_error) begin
                x_latched <= x_position; y_latched <= y_position;
                z_latched <= z_position; gesture_latched <= gesture_code;
                input_valid <= 1'b1;
                xyz_valid_latched <= 1'b1;
            end
        end
    end
endmodule
