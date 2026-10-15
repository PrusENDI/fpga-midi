`timescale 1ns/1ps

module tb_mgc3130_pattern_input;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg report_valid = 1'b0;
    reg xyz_valid = 1'b0;
    reg report_error = 1'b0;
    reg [15:0] x_position = 16'd0;
    reg [15:0] y_position = 16'd0;
    reg [15:0] z_position = 16'd0;
    wire recording;
    wire pattern_commit;
    wire cell_event;
    wire note_on;
    wire note_off;
    wire expression_valid;
    wire [4:0] time_cell;
    wire [6:0] note_number;
    wire [7:0] velocity;

    mgc3130_pattern_input #(
        .X_START(16'h1000), .X_END(16'hF000),
        .Y_MIN(16'h1000), .Y_MAX(16'hF000),
        .START_CONFIRM(3), .END_CONFIRM(3),
        .CELL_CONFIRM(2), .NOTE_CONFIRM(3),
        .TIMEOUT_CYCLES(40)
    ) dut (
        .clk(clk), .rst_n(1'b1),
        .report_valid(report_valid), .xyz_valid(xyz_valid),
        .report_error(report_error),
        .x_position(x_position), .y_position(y_position),
        .z_position(z_position),
        .recording(recording), .pattern_commit(pattern_commit),
        .cell_event(cell_event), .note_on(note_on), .note_off(note_off),
        .expression_valid(expression_valid), .time_cell(time_cell),
        .note_number(note_number), .velocity(velocity)
    );

    task report;
        input [15:0] x;
        input [15:0] y;
        input [15:0] z;
        begin
            @(negedge clk);
            x_position = x; y_position = y; z_position = z;
            xyz_valid = 1'b1; report_valid = 1'b1;
            @(negedge clk);
            report_valid = 1'b0; xyz_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (3) report(16'h1000, 16'h8000, 16'h8000);
        if (!recording) $fatal(1, "left boundary did not start recording");

        repeat (3) report(16'h8000, 16'h8000, 16'hffff);
        if (note_number == 0) $fatal(1, "Y coordinate did not produce a note");
        if (velocity == 0) $fatal(1, "Z coordinate did not produce velocity");

        repeat (3) report(16'hf000, 16'h8000, 16'h8000);
        if (recording) $fatal(1, "right boundary did not stop recording");

        $display("PASS: pattern input state machine");
        $finish;
    end
endmodule
