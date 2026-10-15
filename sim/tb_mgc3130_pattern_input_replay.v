`timescale 1ns/1ps

// Replay a capture_mgc3130.py .hex file into the pattern input.  The default
// interval is 5 ms at 50 MHz (200 reports/s), matching a typical MGC3130
// position report rate.  Override REPORT_INTERVAL_CYCLES for another rate.
module tb_mgc3130_pattern_input_replay #(
    parameter REPLAY_FILE = "mgc3130_capture.hex",
    parameter integer MAX_RECORDS = 10000,
    parameter integer REPORT_INTERVAL_CYCLES = 250000
);
    reg clk = 1'b0;
    always #10 clk = ~clk; // 50 MHz

    reg rst_n = 1'b0;
    reg report_valid = 1'b0;
    reg xyz_valid = 1'b0;
    reg report_error = 1'b0;
    reg [15:0] x_position = 16'd0;
    reg [15:0] y_position = 16'd0;
    reg [15:0] z_position = 16'd0;
    reg [7:0] gesture_code = 8'd0;
    wire recording;
    wire pattern_commit;
    wire cell_event;
    wire note_on;
    wire note_off;
    wire expression_valid;
    wire [4:0] time_cell;
    wire [6:0] note_number;
    wire [7:0] velocity;

    reg [63:0] replay_mem [0:MAX_RECORDS-1];
    integer i;
    integer replay_count;

    mgc3130_pattern_input dut (
        .clk(clk), .rst_n(rst_n),
        .report_valid(report_valid), .xyz_valid(xyz_valid),
        .report_error(report_error),
        .x_position(x_position), .y_position(y_position),
        .z_position(z_position),
        .recording(recording), .pattern_commit(pattern_commit),
        .cell_event(cell_event), .note_on(note_on), .note_off(note_off),
        .expression_valid(expression_valid), .time_cell(time_cell),
        .note_number(note_number), .velocity(velocity)
    );

    initial begin
        for (i = 0; i < MAX_RECORDS; i = i + 1)
            replay_mem[i] = 64'd0;
        $readmemh(REPLAY_FILE, replay_mem);
        replay_count = 0;
        #100;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (i = 0; i < MAX_RECORDS; i = i + 1) begin
            if (!replay_mem[i][0]) begin
                $display("Replay complete: %0d valid reports", replay_count);
                #100;
                $finish;
            end
            @(negedge clk);
            x_position = replay_mem[i][63:48];
            y_position = replay_mem[i][47:32];
            z_position = replay_mem[i][31:16];
            gesture_code = replay_mem[i][15:8];
            xyz_valid = 1'b1;
            report_valid = 1'b1;
            replay_count = replay_count + 1;
            @(negedge clk);
            report_valid = 1'b0;
            xyz_valid = 1'b0;
            repeat (REPORT_INTERVAL_CYCLES) @(posedge clk);
        end
        $display("Replay reached MAX_RECORDS=%0d", MAX_RECORDS);
        $finish;
    end

    always @(posedge clk) begin
        if (note_on || note_off || pattern_commit)
            $display("t=%0t recording=%b note_on=%b note_off=%b commit=%b cell=%0d note=%0d vel=%0d",
                     $time, recording, note_on, note_off, pattern_commit,
                     time_cell, note_number, velocity);
    end
endmodule
