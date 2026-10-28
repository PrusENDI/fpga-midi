// Early hardware-path gate for the V2 audio boundary.
//
// This top deliberately contains only the board oscillator -> GW5A PLL ->
// sample enable -> one fixed DDS oscillator -> PCM5102A I2S path.  It is not
// the production V2 top and must not be used as full-pipeline evidence.
module v2_audio_smoke_top (
  input  logic clk_50m,
  input  logic rst_n,
  output logic pcm5102a_bck,
  output logic pcm5102a_lrck,
  output logic pcm5102a_din
);
  logic clk_sys_100m;
  logic pll_locked;
  logic rst_sys_n;
  logic sample_ce;
  logic [31:0] sample_index;
  logic [31:0] osc_phase;
  logic signed [15:0] osc_sample;

  (* keep = "true" *) logic [31:0] audio_smoke_signature;

  v2_clock_gen u_clock (
    .clk_in(clk_50m), .rst_n(rst_n),
    .clk_sys_100m(clk_sys_100m), .pll_locked(pll_locked)
  );
  v2_reset_sync u_reset (
    .clk_sys_100m(clk_sys_100m), .rst_n(rst_n),
    .pll_locked(pll_locked), .rst_sys_n(rst_sys_n)
  );
  v2_sample_scheduler u_scheduler (
    .clk_sys(clk_sys_100m), .rst_n(rst_sys_n),
    .sample_ce(sample_ce), .sample_index(sample_index)
  );

  function automatic signed [15:0] sine_lut(input logic [3:0] index);
    case (index)
      4'h0: sine_lut = 16'sd0;
      4'h1: sine_lut = 16'sd12539;
      4'h2: sine_lut = 16'sd23170;
      4'h3: sine_lut = 16'sd30273;
      4'h4: sine_lut = 16'sd32767;
      4'h5: sine_lut = 16'sd30273;
      4'h6: sine_lut = 16'sd23170;
      4'h7: sine_lut = 16'sd12539;
      4'h8: sine_lut = -16'sd1;
      4'h9: sine_lut = -16'sd12540;
      4'hA: sine_lut = -16'sd23171;
      4'hB: sine_lut = -16'sd30274;
      4'hC: sine_lut = -16'sd32768;
      4'hD: sine_lut = -16'sd30274;
      4'hE: sine_lut = -16'sd23171;
      default: sine_lut = -16'sd12540;
    endcase
  endfunction

  // 1 kHz at 48 kHz: round(2^32 * 1000 / 48000) = 89,478,485.
  always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      osc_phase  <= 32'd0;
      osc_sample <= 16'sd0;
      audio_smoke_signature <= 32'd0;
    end else begin
      if (sample_ce) begin
        osc_phase  <= osc_phase + 32'd89_478_485;
        osc_sample <= sine_lut(osc_phase[31:28]);
      end
      audio_smoke_signature <= {pll_locked, rst_sys_n, sample_ce,
                                sample_index[13:0], pcm5102a_bck,
                                pcm5102a_lrck, pcm5102a_din, 12'd0};
    end
  end

  i2s_pcm5102a_tx #(.CLK_HZ(100_000_000), .SAMPLE_HZ(48_000)) u_i2s (
    .clk(clk_sys_100m), .rst(!rst_sys_n), .sample_valid(sample_ce),
    .sample_in(osc_sample), .i2s_bck(pcm5102a_bck),
    .i2s_lrck(pcm5102a_lrck), .i2s_din(pcm5102a_din)
  );
endmodule
