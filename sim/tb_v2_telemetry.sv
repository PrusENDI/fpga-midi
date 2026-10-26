`timescale 1ns/1ps
module tb_v2_telemetry;
    logic clk = 1'b0, rst_n = 1'b0;
    logic capture_valid = 1'b0, capture_ready;
    logic [7:0] capture_type, capture_note, capture_flags, capture_tick;
    logic [15:0] capture_sequence;
    logic signed [15:0] capture_x, capture_y, capture_z;
    logic [31:0] capture_voice_bitmap;
    logic [7:0] capture_fifo_level, capture_fault_code;
    logic frame_valid, frame_ready = 1'b0, frame_last;
    logic [7:0] frame_byte;
    logic [7:0] dropped_captures;
    integer i;

    always #5 clk = ~clk;
    v2_telemetry_snapshot dut (.*);

    function automatic [15:0] crc_byte(input [15:0] crc_in, input [7:0] value);
        reg [15:0] c; integer b;
        begin
            c = crc_in ^ {value,8'h00};
            for (b = 0; b < 8; b = b + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction

    task automatic capture(input [15:0] seq, input [7:0] note);
        begin
            @(negedge clk);
            capture_sequence = seq; capture_note = note;
            capture_type = 8'h01; capture_x = -16'sd100; capture_y = 16'sd200;
            capture_z = -16'sd300; capture_flags = 8'h05; capture_tick = 8'h2a;
            capture_voice_bitmap = 32'h12345678; capture_fifo_level = 8'h34;
            capture_fault_code = 8'h00; capture_valid = 1'b1;
            @(posedge clk);
            if (!capture_ready) $fatal(1, "capture unexpectedly not ready");
            @(negedge clk); capture_valid = 1'b0;
        end
    endtask

    task automatic collect_and_check(input [15:0] seq, input [7:0] note);
        reg [7:0] got [0:21];
        reg [15:0] c;
        integer k;
        begin
            frame_ready = 1'b1;
            for (k = 0; k < 22; k = k + 1) begin
                while (!frame_valid) @(negedge clk);
                got[k] = frame_byte;
                if (k == 21 && !frame_last) $fatal(1, "frame_last missing");
                @(posedge clk); #1;
            end
            frame_ready = 1'b0;
            if (got[0] !== 8'h5a || got[1] !== 8'h02 || got[2] !== 8'h01 ||
                got[3] !== seq[15:8] || got[4] !== seq[7:0] ||
                got[11] !== note || got[12] !== 8'h05 || got[13] !== 8'h2a ||
                got[14] !== 8'h12 || got[17] !== 8'h78 || got[18] !== 8'h34 ||
                got[19] !== 8'h00)
                $fatal(1, "telemetry body mismatch for seq %h", seq);
            c = 16'hffff;
            for (k = 0; k < 20; k = k + 1) c = crc_byte(c, got[k]);
            if ({got[20],got[21]} !== c)
                $fatal(1, "telemetry CRC mismatch");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // First frame remains stable while TX is stopped; second fills the
        // other bank, and a third capture is counted as dropped.
        capture(16'h0102, 8'h41);
        if (!frame_valid || !capture_ready) $fatal(1, "first capture state mismatch");
        frame_ready = 1'b0;
        capture(16'h0304, 8'h42);
        if (capture_ready) $fatal(1, "full double buffer reported ready");
        @(negedge clk); capture_valid = 1'b1;
        @(posedge clk); @(negedge clk); capture_valid = 1'b0;
        if (dropped_captures !== 8'd1) $fatal(1, "dropped capture count mismatch");

        collect_and_check(16'h0102, 8'h41);

        // Capture exactly on the final byte of the active frame. The newly
        // captured bank must become the next active frame without a bubble.
        frame_ready = 1'b1;
        while (!frame_valid) @(posedge clk);
        for (i = 0; i < 21; i = i + 1) @(posedge clk);
        @(negedge clk);
        capture_sequence = 16'h0506; capture_note = 8'h43;
        capture_type = 8'h01; capture_x = -16'sd100; capture_y = 16'sd200;
        capture_z = -16'sd300; capture_flags = 8'h05; capture_tick = 8'h2a;
        capture_voice_bitmap = 32'h12345678; capture_fifo_level = 8'h34;
        capture_fault_code = 8'h00; capture_valid = 1'b1;
        @(posedge clk);
        if (!frame_last) $fatal(1, "expected final byte handshake");
        @(negedge clk); capture_valid = 1'b0; frame_ready = 1'b0;
        @(posedge clk);
        if (!frame_valid || frame_byte !== 8'h5a)
            $fatal(1, "simultaneous final TX/capture lost next frame");
        collect_and_check(16'h0506, 8'h43);

        $display("tb_v2_telemetry PASS");
        $finish;
    end
endmodule
