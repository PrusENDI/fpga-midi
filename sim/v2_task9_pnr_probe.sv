`timescale 1ns/1ps
// Small-pin P&R probe. Internal controls are deliberately stateful so the
// complete DPB-backed storage remains observable without exceeding package
// I/O limits.
module v2_task9_pnr_probe (
    input logic clk, input logic rst_n, input logic sample_ce,
    input logic signed [15:0] audio_in,
    output logic signed [15:0] audio_out,
    output logic [7:0] diag,
    output logic [1:0] fx_status_level,
    output logic fx_clip
);
    logic [15:0] tick;
    logic wt_write_valid, wt_write_ready;
    logic [1:0] wt_table, wt_apply_table, wt_read_table;
    logic [9:0] wt_index, wt_read_index;
    logic signed [15:0] wt_write_sample, wt_read_sample;
    logic wt_crc_valid, wt_apply_valid, wt_apply_ready;
    logic [15:0] wt_expected_crc, wt_apply_version;
    logic loop_boundary, idle, wt_active_valid, wt_shadow_valid, wt_apply_busy, wt_crc_error;
    logic [15:0] wt_active_version;
    logic [1:0] wt_active_table;
    logic fx_enable;
    logic [1:0] fx_level;
    logic [17:0] fx_gain_q16;
    logic [15:0] fx_cutoff_q16, fx_feedback_q15, fx_reverb_mix_q15;
    logic [9:0] fx_delay_samples;
    logic patch_write_valid, patch_write_ready, patch_crc_valid, patch_apply_valid, patch_apply_ready;
    logic [1:0] patch_family;
    logic [2:0] patch_track;
    logic [7:0] patch_index;
    logic signed [31:0] patch_write_value, patch_active_value;
    logic [15:0] patch_expected_crc, patch_expected_version, patch_active_version;
    logic patch_dirty, patch_crc_ok, patch_apply_busy;
    logic [7:0] patch_last_error;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tick <= 16'd0;
        else tick <= tick + 16'd1;
    end
    assign wt_table = 2'd0;
    assign wt_index = tick[9:0];
    assign wt_write_sample = $signed(tick);
    assign wt_write_valid = rst_n && tick[10];
    assign wt_crc_valid = 1'b0;
    assign wt_expected_crc = 16'hffff;
    assign wt_apply_valid = 1'b0;
    assign wt_apply_table = 2'd0;
    assign wt_apply_version = 16'd0;
    assign loop_boundary = tick[11] & ~tick[10];
    assign idle = tick[12];
    assign wt_read_table = tick[13:12] % 3;
    assign wt_read_index = tick[9:0];
    assign fx_enable = 1'b1;
    assign fx_level = tick[1:0];
    assign fx_gain_q16 = 18'd65536 + {10'd0, tick[7:0]};
    assign fx_cutoff_q16 = 16'd32768 + {8'd0, tick[7:0]};
    assign fx_delay_samples = tick[9:0];
    assign fx_feedback_q15 = 16'd4096;
    assign fx_reverb_mix_q15 = 16'd4096;
    assign patch_family = 2'd0;
    assign patch_track = 3'd0;
    assign patch_index = 8'd0;
    assign patch_write_value = 32'd1;
    assign patch_write_valid = rst_n && tick[3];
    assign patch_crc_valid = 1'b0;
    assign patch_expected_crc = 16'hffff;
    assign patch_apply_valid = 1'b0;
    assign patch_expected_version = 16'd0;

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
    v2_patch_bank #(.USE_GOWIN_RAM(1)) patch (
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
    assign diag = {wt_active_valid, wt_shadow_valid, wt_apply_busy, wt_crc_error,
                   patch_dirty, patch_crc_ok, patch_apply_busy, fx_clip};
endmodule
