`timescale 1ns/1ps
// Dynamic-pin Task 9 resource probe. All upload, patch and FX controls are
// ports so Gowin cannot sweep the storage behind constant initial values.
module v2_wavetable_fx_probe (
    input logic clk, input logic rst_n, input logic sample_ce,
    input logic signed [15:0] audio_in,
    input logic wt_write_valid, input logic [1:0] wt_table,
    input logic [9:0] wt_index, input logic signed [15:0] wt_write_sample,
    input logic wt_crc_valid, input logic [15:0] wt_expected_crc,
    input logic wt_apply_valid, input logic [1:0] wt_apply_table,
    input logic [15:0] wt_apply_version, input logic loop_boundary, input logic idle,
    input logic [1:0] wt_read_table, input logic [9:0] wt_read_index,
    input logic fx_enable, input logic [1:0] fx_level,
    input logic [17:0] fx_gain_q16, input logic [15:0] fx_cutoff_q16,
    input logic [9:0] fx_delay_samples, input logic [15:0] fx_feedback_q15,
    input logic [15:0] fx_reverb_mix_q15,
    input logic patch_write_valid, input logic [1:0] patch_family,
    input logic [2:0] patch_track, input logic [7:0] patch_index,
    input logic signed [31:0] patch_write_value,
    input logic patch_crc_valid, input logic [15:0] patch_expected_crc,
    input logic patch_apply_valid, input logic [15:0] patch_expected_version,
    output logic signed [15:0] audio_out,
    output logic [1:0] fx_status_level, output logic fx_clip,
    output logic wt_write_ready, output logic wt_apply_ready,
    output logic wt_active_valid, output logic wt_shadow_valid,
    output logic wt_apply_busy, output logic wt_crc_error,
    output logic [15:0] wt_active_version, output logic [1:0] wt_active_table,
    output logic signed [15:0] wt_read_sample,
    output logic patch_write_ready, output logic patch_apply_ready,
    output logic signed [31:0] patch_active_value,
    output logic [15:0] patch_active_version, output logic patch_dirty,
    output logic patch_crc_ok, output logic patch_apply_busy,
    output logic [7:0] patch_last_error
);
    v2_wavetable_loader #(.USE_GOWIN_RAM(1)) wt (
        .clk, .rst_n, .wt_write_valid, .wt_write_ready, .wt_table, .wt_index,
        .wt_write_sample, .wt_crc_valid, .wt_expected_crc, .wt_apply_valid,
        .wt_apply_ready, .wt_apply_table, .wt_apply_version, .loop_boundary,
        .idle, .wt_read_table, .wt_read_index, .wt_read_sample,
        .wt_active_valid, .wt_shadow_valid, .wt_apply_busy, .wt_crc_error,
        .wt_active_version, .wt_active_table
    );
    v2_fx_lite #(.USE_GOWIN_RAM(1)) fx (
        .clk, .rst_n, .sample_ce, .audio_in, .audio_out, .fx_enable, .fx_level,
        .fx_gain_q16, .fx_cutoff_q16, .fx_delay_samples, .fx_feedback_q15,
        .fx_reverb_mix_q15, .fx_status_level, .fx_clip
    );
    v2_patch_bank #(.USE_GOWIN_RAM(1)) patch_bank (
        .clk, .rst_n, .select_family(patch_family), .select_track(patch_track),
        .select_index(patch_index), .write_valid(patch_write_valid),
        .write_ready(patch_write_ready), .write_value(patch_write_value),
        .active_value(patch_active_value), .crc_valid(patch_crc_valid),
        .expected_crc(patch_expected_crc), .apply_valid(patch_apply_valid),
        .apply_ready(patch_apply_ready), .expected_version(patch_expected_version),
        .idle, .loop_boundary, .active_version(patch_active_version),
        .shadow_dirty(patch_dirty), .crc_ok(patch_crc_ok),
        .apply_busy(patch_apply_busy), .last_error(patch_last_error)
    );
endmodule
