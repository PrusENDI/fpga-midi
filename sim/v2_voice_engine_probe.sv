`timescale 1ns/1ps
// Small-pin synthesis/P&R wrapper. It keeps the complete 32-slot engine in
// the netlist while presenting a board-sized control surface for the timing
// probe; the real V2 top supplies the frozen 96-bit event bus in Task 12.
module v2_voice_engine_probe (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               event_valid,
    input  logic [3:0]         event_type,
    input  logic [7:0]         note,
    input  logic [7:0]         velocity,
    input  logic signed [15:0] pitch_mod,
    output logic signed [15:0] mixed_sample,
    output logic               sample_valid,
    output logic               voice_overflow,
    output logic [5:0]         active_voice_count
);
    logic [95:0] event_data;
    logic event_ready;
    logic [31:0] active_bitmap;

    assign event_data = {
        1'b0, event_type, 3'd0, 8'd0, 8'd0, note, velocity,
        pitch_mod, 16'd0, 8'd0, 16'd0
    };

    v2_voice_engine_mux #(.VOICES(32)) engine (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_data(event_data), .mixed_sample(mixed_sample),
        .sample_valid(sample_valid), .active_bitmap(active_bitmap),
        .voice_overflow(voice_overflow), .revoice_count(),
        .active_voice_count(active_voice_count)
    );
endmodule
