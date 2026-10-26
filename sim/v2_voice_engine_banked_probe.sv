`timescale 1ns/1ps
module v2_voice_engine_banked_probe (
    input logic clk, input logic rst_n, input logic sample_ce,
    input logic event_valid, input logic [3:0] event_type,
    input logic [7:0] note, input logic [7:0] velocity,
    input logic signed [15:0] pitch_mod,
    output logic signed [15:0] mixed_sample, output logic sample_valid,
    output logic voice_overflow, output logic [5:0] active_voice_count
);
    logic [95:0] event_data;
    logic event_ready;
    logic [31:0] active_bitmap;
    assign event_data = {
        1'b0, event_type, 3'd0, 8'd0, 8'd0, note, velocity,
        pitch_mod, 16'd0, 8'd0, 16'd0
    };
    v2_voice_engine_banked #(.VOICES(32), .USE_GOWIN_RAM(1)) engine (
        .clk, .rst_n, .sample_ce, .event_valid, .event_ready, .event_data,
        .mixed_sample, .sample_valid, .active_bitmap, .voice_overflow,
        .revoice_count(), .active_voice_count
    );
endmodule
