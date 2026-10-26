`timescale 1ns/1ps
module tb_v2_voice_engine;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic sample_ce = 1'b0;
    logic event_valid = 1'b0;
    logic [95:0] event_data = 96'd0;
    logic event_ready;
    logic signed [15:0] mixed_sample;
    logic sample_valid;
    logic [31:0] active_bitmap;
    logic voice_overflow;
    logic [7:0] revoice_count;
    logic [5:0] active_voice_count;
    integer i;
    integer samples;
    logic [31:0] phase_before;
    logic [31:0] bitmap_before;

    always #5 clk = ~clk;

    v2_voice_engine_mux dut (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_data(event_data), .mixed_sample(mixed_sample),
        .sample_valid(sample_valid), .active_bitmap(active_bitmap),
        .voice_overflow(voice_overflow), .revoice_count(revoice_count),
        .active_voice_count(active_voice_count)
    );

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            event_valid = 1'b0;
            sample_ce = 1'b0;
            repeat (2) @(posedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    task automatic send_event(
        input logic [3:0] typ,
        input logic [7:0] note_value,
        input logic signed [15:0] pitch_mod,
        input logic [15:0] timbre_mod,
        input logic [7:0] velocity
    );
        integer wait_cycles;
        begin
            @(negedge clk);
            event_data = 96'd0;
            event_data[94:91] = typ;
            event_data[71:64] = note_value;
            event_data[63:56] = velocity;
            event_data[55:40] = pitch_mod;
            event_data[39:24] = timbre_mod;
            event_valid = 1'b1;
            wait_cycles = 0;
            while (!event_ready) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 200) $fatal(1, "event ready timeout typ=%0d note=%0d", typ, note_value);
            end
            @(posedge clk);
            #1 event_valid = 1'b0;
        end
    endtask

    task automatic sample_once;
        integer wait_cycles;
        begin
            @(negedge clk);
            sample_ce = 1'b1;
            @(posedge clk);
            #1 sample_ce = 1'b0;
            wait_cycles = 0;
            while (!sample_valid) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 100) $fatal(1, "sample valid timeout index=%0d active=%b", dut.scan_index, dut.scan_active);
            end
            #1;
        end
    endtask

    initial begin
        // 1-slot lifecycle, revoice phase preservation, and signed detune.
        $display("phase 1");
        reset_dut();
        send_event(4'd1, 8'd60, 16'sd0, 16'd0, 8'd200);
        if (active_voice_count !== 6'd1) $fatal(1, "one voice allocation");
        phase_before = dut.phase_a[0];
        send_event(4'd3, 8'd60, 16'sd4096, 16'd0, 8'd200);
        if (revoice_count !== 8'd1) $fatal(1, "revoice count");
        if (dut.phase_a[0] !== phase_before) $fatal(1, "revoice reset phase");
        if (dut.target_a[0] === dut.target_b[0]) $fatal(1, "detune targets equal");
        sample_once();
        if (dut.scan_base !== 6'd1) $fatal(1, "round robin base did not advance");
        if (dut.envelope[0] == 16'd0) $fatal(1, "attack did not advance");

        // 8 and 32 note allocation uses free-first slots.
        $display("phase 2");
        reset_dut();
        for (i = 0; i < 8; i = i + 1)
            send_event(4'd1, 8'd60 + i, 16'sd0, 16'd0, 8'd255);
        if (active_voice_count !== 6'd8) $fatal(1, "eight voice allocation");
        for (i = 8; i < 32; i = i + 1)
            send_event(4'd1, 8'd60 + (i % 8), 16'sd0, 16'd0, 8'd255);
        if (active_voice_count !== 6'd32) $fatal(1, "thirty-two voice allocation");
        bitmap_before = active_bitmap;
        send_event(4'd1, 8'd100, 16'sd0, 16'd0, 8'd255);
        if (!voice_overflow || active_bitmap !== bitmap_before)
            $fatal(1, "33rd note changed existing voices");

        // Hold an event through the busy sample scan: it must not mutate state
        // until ready returns, then it is accepted exactly once.
        @(negedge clk);
        sample_ce = 1'b1;
        @(posedge clk);
        #1 sample_ce = 1'b0;
        @(negedge clk);
        event_data = 96'd0;
        event_data[94:91] = 4'd2;
        event_data[71:64] = 8'd60;
        event_valid = 1'b1;
        bitmap_before = active_bitmap;
        if (active_bitmap !== bitmap_before) $fatal(1, "state changed before event handshake");
        while (!event_ready) @(negedge clk);
        @(posedge clk);
        #1 event_valid = 1'b0;
        while (!sample_valid) @(posedge clk);

        // A full 32-voice, full-velocity run must hit the explicit mixer
        // limiter as the shared saw phase crosses the positive rail.
        reset_dut();
        for (i = 0; i < 32; i = i + 1)
            send_event(4'd1, 8'd60, 16'sd0, 16'd0, 8'd255);
        for (i = 0; i < 20; i = i + 1)
            sample_once();
        samples = 0;
        while (samples < 16 && mixed_sample !== 16'sh7FFF && mixed_sample !== -16'sd32768) begin
            sample_once();
            samples = samples + 1;
        end
        if (samples == 16) $fatal(1, "mixer saturation");

        // NOTE_OFF enters release and eventually frees the matching slot.
        send_event(4'd2, 8'd60, 16'sd0, 16'd0, 8'd0);
        samples = 0;
        while (active_bitmap[0] && samples < 80) begin
            sample_once();
            samples = samples + 1;
        end
        if (active_bitmap[0]) $fatal(1, "release lifecycle");
        $display("tb_v2_voice_engine PASS voices=32 scan_cycles=32 release_samples=%0d", samples);
        $finish;
    end
endmodule
