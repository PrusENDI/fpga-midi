// Task 12 diagnostic wrapper.
//
// The board-facing V2 top has intentionally small external I/O.  Gowin's
// optimizer can therefore remove an otherwise reachable control/audio branch
// when a probe build has no stimulus on that branch.  This wrapper exposes
// registered/internal milestones as diagnostic pins so the routed report
// measures the actual V2 pipeline rather than a mostly swept netlist.  It is
// not a second user-facing top and does not change the board pin contract.
module v2_top_observable_probe (
    input  wire       clk_50m,
    inout  wire       mgc_sda,
    inout  wire       mgc_scl,
    inout  wire       mgc_ts,
    inout  wire       mgc_mclr,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire       pcm5102a_bck,
    output wire       pcm5102a_lrck,
    output wire       pcm5102a_din,
    // The two buses keep the diagnostic wrapper below the GW5A package I/O
    // limit while still making every major pipeline boundary observable.
    output wire [31:0] probe_audio_state,
    output wire [23:0] probe_control_state
);
    mgc3130_v2_top #(
        .USE_MGC_READER(1),
        .USE_GOWIN_RAM(1),
        .USE_POTTS(0)
    ) u_v2 (
        .clk_50m,
        .mgc_sda,
        .mgc_scl,
        .mgc_ts,
        .mgc_mclr,
        .uart_rx,
        .uart_tx,
        .pcm5102a_bck,
        .pcm5102a_lrck,
        .pcm5102a_din
    );

    // Keep the observability aliases registered at their source boundaries.
    // The reduction/packing is deliberately simple so it cannot become a
    // second timing path in the implementation under test.
    assign probe_audio_state = u_v2.voice_bitmap ^ u_v2.sample_index ^
                               {{16{u_v2.fx_sample[15]}}, u_v2.fx_sample};
    assign probe_control_state[7:0] = u_v2.audio_cursor_x[7:0] ^
                                      u_v2.audio_cursor_y[7:0] ^
                                      u_v2.audio_cursor_z[7:0] ^
                                      {5'd0, u_v2.mode_reg};
    assign probe_control_state[15:8] = u_v2.protocol_error ^ u_v2.tlm_frame_byte ^
                                       {6'd0, u_v2.potts_busy, u_v2.potts_done};
    assign probe_control_state[23:16] = {
        u_v2.tlm_frame_valid,
        u_v2.audio_cursor_valid,
        u_v2.valid_frame,
        u_v2.calibrated_valid,
        u_v2.live_event_valid,
        u_v2.loop_event_valid,
        u_v2.loop_active_valid,
        u_v2.pll_locked
    };
endmodule
