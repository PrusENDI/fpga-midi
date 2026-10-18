// Temporary calibration-only board top.  It intentionally excludes the Loop
// command plane and audio path; C3 carries only framed raw reader samples.
module mgc3130_uart_calibration_top #(
    parameter integer RESET_LOW_MS = 250,
    parameter integer STARTUP_WAIT_MS = 2000,
    parameter [31:0] BUILD_TAG = 32'h43414C31
) (
    input wire clk_50m,
    inout wire mgc_sda, inout wire mgc_scl, inout wire mgc_ts,
    inout wire mgc_mclr,
    output wire uart_tx,
    input wire uart_rx,
    output wire pcm5102a_bck, output wire pcm5102a_lrck, output wire pcm5102a_din
);
    wire mclr_drive_low, mgc_ready;
    assign mgc_mclr = mclr_drive_low ? 1'b0 : 1'bz;
    assign pcm5102a_bck = 1'b0;
    assign pcm5102a_lrck = 1'b0;
    assign pcm5102a_din = 1'b0;
    wire unused_uart_rx = uart_rx;

    mgc3130_reset_seq #(.CLK_HZ(50_000_000), .RESET_LOW_MS(RESET_LOW_MS),
        .STARTUP_WAIT_MS(STARTUP_WAIT_MS)) reset_seq (
        .clk(clk_50m), .mclr_drive_low(mclr_drive_low), .ready(mgc_ready));

    wire report_valid, xyz_valid, report_error, touch_valid, reader_busy;
    wire [31:0] touch_info, debug_error_context;
    wire [15:0] x_position, y_position, z_position, debug_output_mask;
    wire [7:0] gesture_code, debug_message_size;
    wire [3:0] error_code;
    mgc3130_reader reader (
        .clk(clk_50m), .rst_n(mgc_ready), .i2c_sda(mgc_sda), .i2c_scl(mgc_scl),
        .mgc_ts(mgc_ts), .report_valid(report_valid), .xyz_valid(xyz_valid),
        .x_position(x_position), .y_position(y_position), .z_position(z_position),
        .gesture_code(gesture_code), .report_error(report_error),
        .error_code(error_code), .busy(reader_busy),
        .debug_error_context(debug_error_context), .debug_output_mask(debug_output_mask),
        .debug_message_size(debug_message_size), .touch_info(touch_info),
        .touch_valid(touch_valid));

    wire capture_valid, capture_ready;
    wire [7:0] capture_data;
    wire capture_overflow;
    wire [15:0] report_sequence;
    mgc3130_calibration_capture #(.BUILD_TAG(BUILD_TAG)) capture (
        .clk(clk_50m), .rst_n(mgc_ready), .mgc_ready(mgc_ready),
        .report_valid(report_valid), .xyz_valid(xyz_valid), .report_error(report_error),
        .touch_valid(touch_valid), .touch_info(touch_info),
        .x_position(x_position), .y_position(y_position), .z_position(z_position),
        .gesture_code(gesture_code), .error_code(error_code), .reader_busy(reader_busy),
        .tx_valid(capture_valid), .tx_ready(capture_ready), .tx_data(capture_data),
        .capture_overflow(capture_overflow), .report_sequence(report_sequence));
    uart_byte_serializer #(.CLK_HZ(50_000_000), .BAUD(115_200)) serializer (
        .clk(clk_50m), .rst(!mgc_ready), .in_valid(capture_valid),
        .in_ready(capture_ready), .in_data(capture_data), .tx(uart_tx), .busy());
endmodule
