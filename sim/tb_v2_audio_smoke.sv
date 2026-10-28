`timescale 1ns/1ps

module tb_v2_audio_smoke;
  logic clk_50m = 1'b0;
  logic rst_n = 1'b0;
  wire pcm5102a_bck;
  wire pcm5102a_lrck;
  wire pcm5102a_din;
  integer sample_count = 0;
  integer sample_intervals = 0;
  integer interval_2083 = 0;
  integer interval_2084 = 0;
  integer cycles_since_sample = 0;
  integer bck_edges = 0;
  integer lrck_rises = 0;
  integer din_changes = 0;
  integer nonzero_samples = 0;
  integer last_din = 0;
  integer i;

  always #5 clk_50m = ~clk_50m;

  v2_audio_smoke_top dut (
    .clk_50m(clk_50m),
    .rst_n(rst_n),
    .pcm5102a_bck(pcm5102a_bck),
    .pcm5102a_lrck(pcm5102a_lrck),
    .pcm5102a_din(pcm5102a_din)
  );

  always @(posedge clk_50m) begin
    if (dut.rst_sys_n) begin
      cycles_since_sample = cycles_since_sample + 1;
      if (dut.sample_ce) begin
        if (sample_count > 0) begin
          sample_intervals = sample_intervals + 1;
          if (cycles_since_sample == 2083) interval_2083 = interval_2083 + 1;
          else if (cycles_since_sample == 2084) interval_2084 = interval_2084 + 1;
          else $fatal(1, "unexpected sample interval %0d", cycles_since_sample);
        end
        sample_count = sample_count + 1;
        if (dut.osc_sample != 0) nonzero_samples = nonzero_samples + 1;
        cycles_since_sample = 0;
      end
      if (pcm5102a_din !== last_din) din_changes = din_changes + 1;
      last_din = pcm5102a_din;
    end
  end

  always @(posedge pcm5102a_bck) bck_edges = bck_edges + 1;
  always @(posedge pcm5102a_lrck) lrck_rises = lrck_rises + 1;

  initial begin
    // Ten milliseconds at the simulation's 100 MHz clock gives enough
    // samples to exercise the 2083/2084 cadence and several I2S frames.
    repeat (8) @(posedge clk_50m);
    rst_n = 1'b1;
    for (i = 0; i < 1_000_000; i = i + 1) @(posedge clk_50m);
    #1;
    if (!dut.pll_locked || !dut.rst_sys_n)
      $fatal(1, "audio smoke clock/reset did not come up");
    if (sample_count < 470 || sample_count > 490)
      $fatal(1, "sample count %0d outside 10 ms expectation", sample_count);
    if (sample_intervals != sample_count - 1 || interval_2083 == 0 || interval_2084 == 0)
      $fatal(1, "sample cadence missing 2083/2084 intervals: samples=%0d i2083=%0d i2084=%0d",
             sample_count, interval_2083, interval_2084);
    if (nonzero_samples < 100)
      $fatal(1, "single oscillator did not produce nonzero samples: %0d", nonzero_samples);
    if (bck_edges < 10_000 || lrck_rises < 100 || din_changes < 100)
      $fatal(1, "I2S activity too low: bck=%0d lrck_rises=%0d din_changes=%0d",
             bck_edges, lrck_rises, din_changes);
    $display("tb_v2_audio_smoke PASS samples=%0d i2083=%0d i2084=%0d bck_edges=%0d lrck_rises=%0d",
             sample_count, interval_2083, interval_2084, bck_edges, lrck_rises);
    $finish;
  end
  initial begin
    #20_000_000;
    $fatal(1, "audio smoke timeout");
  end
endmodule
