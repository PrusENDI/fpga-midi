// Task 12 diagnostic probe: retain valid input activity and enable the
// contract Potts commit path in the independent V2 top.
module v2_top_timing_probe_valid_potts_static (
    input wire clk_50m,
    inout wire mgc_sda, inout wire mgc_scl, inout wire mgc_ts,
    inout wire mgc_mclr, input wire uart_rx, output wire uart_tx,
    output wire pcm5102a_bck, output wire pcm5102a_lrck,
    output wire pcm5102a_din, output wire [7:0] probe_status
);
    mgc3130_v2_top #(
        .USE_MGC_READER(0), .USE_GOWIN_RAM(1), .USE_POTTS(1),
        .PRESERVE_LOOP_PLANE(1), .PRESERVE_INPUT_PLANE(1),
        .PRESERVE_INPUT_VALID(1), .PRESERVE_POTTS_PLANE(1)
    ) u_v2 (
        .clk_50m, .mgc_sda, .mgc_scl, .mgc_ts, .mgc_mclr, .uart_rx,
        .uart_tx, .pcm5102a_bck, .pcm5102a_lrck, .pcm5102a_din
    );
    assign probe_status[0] = ^u_v2.voice_bitmap;
    assign probe_status[1] = ^u_v2.sample_index;
    assign probe_status[2] = u_v2.voice_sample_valid ^ u_v2.sample_ce;
    assign probe_status[3] = u_v2.audio_cursor_valid ^ u_v2.valid_frame ^ u_v2.calibrated_valid;
    assign probe_status[4] = u_v2.live_event_valid ^ u_v2.record_write_valid ^ ^u_v2.record_event_data;
    assign probe_status[5] = ^u_v2.v2_loop_debug_signature;
    assign probe_status[6] = ^u_v2.protocol_error ^ ^u_v2.tlm_frame_byte;
    assign probe_status[7] = u_v2.pll_locked ^ u_v2.tlm_frame_valid ^ u_v2.potts_busy;
endmodule
