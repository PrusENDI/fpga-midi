// Synthesis/P&R probe for the real V2 sensor build.  The simulation top uses
// the deterministic sensor stub, while this probe keeps the existing official
// MGC3130 reader and its I2C IP in the mapped design.
module v2_top_synth_probe (
    input  wire clk_50m,
    inout  wire mgc_sda,
    inout  wire mgc_scl,
    inout  wire mgc_ts,
    inout  wire mgc_mclr,
    input  wire uart_rx,
    output wire uart_tx,
    output wire pcm5102a_bck,
    output wire pcm5102a_lrck,
    output wire pcm5102a_din
);
    mgc3130_v2_top #(
        .USE_MGC_READER(1),
        .USE_GOWIN_RAM(1),
        .USE_POTTS(0),
        .FX_ENABLE(1),
        .FX_LEVEL(1)
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
endmodule
