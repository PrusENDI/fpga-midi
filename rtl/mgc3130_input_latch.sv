// Capture one complete MGC3130 report in the 50 MHz FPGA clock domain.
module mgc3130_input_latch (
    input wire clk, input wire rst_n,
    input wire report_valid, input wire xyz_valid, input wire report_error,
    input wire [15:0] x_position, input wire [15:0] y_position,
    input wire [15:0] z_position, input wire [7:0] gesture_code,
    output reg input_valid, output reg xyz_valid_latched,
    output reg [15:0] x_latched, output reg [15:0] y_latched,
    output reg [15:0] z_latched, output reg [7:0] gesture_latched
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_valid <= 1'b0;
            xyz_valid_latched <= 1'b0;
            x_latched <= 16'd0; y_latched <= 16'd0; z_latched <= 16'd0;
            gesture_latched <= 8'd0;
        end else begin
            input_valid <= 1'b0;
            xyz_valid_latched <= 1'b0;
            if (report_valid && xyz_valid && !report_error) begin
                x_latched <= x_position; y_latched <= y_position;
                z_latched <= z_position; gesture_latched <= gesture_code;
                input_valid <= 1'b1;
                xyz_valid_latched <= 1'b1;
            end
        end
    end
endmodule
