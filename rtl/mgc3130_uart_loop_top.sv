// Production board entry point for the Loop-enabled design.
//
// Keeping the feature selection in a wrapper avoids relying on a GUI-specific
// Verilog parameter override.  The legacy top remains available for the
// diagnostic/ASCII build, while this module always routes B3/C3 through the
// binary Loop control path and selects the Loop mixer for audio.
module mgc3130_uart_loop_top (
    input  wire clk_50m,
    inout  wire mgc_sda,
    inout  wire mgc_scl,
    inout  wire mgc_ts,
    inout  wire mgc_mclr,
    output wire uart_tx,
    input  wire uart_rx,
    output wire pcm5102a_bck,
    output wire pcm5102a_lrck,
    output wire pcm5102a_din
);
    mgc3130_uart_top #(
        .AUDIO_STREAM        (0),
        .AUDIO_OUTPUT        (1),
        .LOOP_CONTROL_ENABLE (1),
        .USE_GOWIN_UART_FIFO (1),
        .USE_REF_UART_RX     (1),
        .RESET_LOW_MS        (250),
        .STARTUP_WAIT_MS     (2000)
    ) u_top (
        .clk_50m       (clk_50m),
        .mgc_sda       (mgc_sda),
        .mgc_scl       (mgc_scl),
        .mgc_ts        (mgc_ts),
        .mgc_mclr      (mgc_mclr),
        .uart_tx       (uart_tx),
        .uart_rx       (uart_rx),
        .pcm5102a_bck  (pcm5102a_bck),
        .pcm5102a_lrck (pcm5102a_lrck),
        .pcm5102a_din  (pcm5102a_din)
    );
endmodule
