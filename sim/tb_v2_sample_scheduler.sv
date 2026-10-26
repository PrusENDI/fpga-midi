`timescale 1ns/1ps

module tb_v2_sample_scheduler;
  logic clk_sys = 1'b0;
  logic rst_n = 1'b0;
  logic sample_ce;
  logic [31:0] sample_index;
  integer ce_count = 0;
  integer interval_count = 0;
  integer interval_2083 = 0;
  integer interval_2084 = 0;
  integer cycles_since_ce = 0;
  integer i;

  always #5 clk_sys = ~clk_sys;

  v2_sample_scheduler dut (
    .clk_sys(clk_sys), .rst_n(rst_n),
    .sample_ce(sample_ce), .sample_index(sample_index)
  );

  always @(posedge clk_sys) begin
    if (!rst_n) begin
      cycles_since_ce = 0;
    end else begin
      cycles_since_ce = cycles_since_ce + 1;
      if (sample_ce) begin
        if (ce_count > 0) begin
          interval_count = interval_count + 1;
          if (cycles_since_ce == 2083) interval_2083 = interval_2083 + 1;
          else if (cycles_since_ce == 2084) interval_2084 = interval_2084 + 1;
          else $fatal(1, "unexpected sample interval %0d", cycles_since_ce);
        end
        ce_count = ce_count + 1;
        cycles_since_ce = 0;
      end
    end
  end

  initial begin
    repeat (4) @(posedge clk_sys);
    rst_n = 1'b1;
    // 100,000,000 system-clock cycles is exactly one second at 100 MHz.
    for (i = 0; i < 100_000_000; i = i + 1) @(posedge clk_sys);
    // Observe the registered enable from the final system-clock edge.
    @(posedge clk_sys);
    if (ce_count != 48_000) $fatal(1, "sample_ce count %0d, expected 48000", ce_count);
    if (interval_2083 + interval_2084 != 47_999)
      $fatal(1, "interval count %0d, expected 47999", interval_2083 + interval_2084);
    if (interval_2083 == 0 || interval_2084 == 0)
      $fatal(1, "expected both 2083 and 2084 cycle intervals");
    if (sample_index != 48_000)
      $fatal(1, "sample_index %0d, expected 48000", sample_index);
    $display("tb_v2_sample_scheduler PASS ce=%0d interval_2083=%0d interval_2084=%0d index=%0d",
             ce_count, interval_2083, interval_2084, sample_index);
    $finish;
  end
endmodule
