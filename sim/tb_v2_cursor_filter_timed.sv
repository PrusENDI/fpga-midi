`timescale 1ns/1ps
module tb_v2_cursor_filter_timed;
  logic clk = 0, rst_n = 0, frame_in_valid = 0, sample_ce = 0;
  logic signed [31:0] frame_x = 0, frame_y = 0, frame_z = 0;
  logic frame_valid = 1, frame_saturated = 0, frame_gap = 0, frame_degraded = 0, left_edge = 0;
  logic [7:0] calibration_reason = 0;
  logic [15:0] frame_sequence = 0;
  logic [31:0] frame_timestamp = 0;
  logic signed [31:0] cursor_x, cursor_y, cursor_z;
  logic [15:0] normalized_pitch, velocity_control, depth_control;
  logic [1:0] state;
  logic point_valid, rebased, stable_valid, audio_valid, frame_output_valid;
  logic signed [31:0] audio_cursor_x, audio_cursor_y, audio_cursor_z;
  logic [15:0] audio_pitch, audio_velocity, audio_depth, audio_sequence;
  logic [31:0] audio_timestamp;

  always #5 clk = ~clk;

  v2_cursor_filter_timed #(.SETTLE_TICKS(0), .MAX_STEP_Q16(8192)) dut (
    .clk, .rst_n, .frame_in_valid, .frame_x, .frame_y, .frame_z,
    .frame_valid, .frame_saturated, .frame_gap, .frame_degraded,
    .calibration_reason, .frame_sequence, .frame_timestamp, .left_edge,
    .sample_ce, .cursor_x, .cursor_y, .cursor_z, .normalized_pitch,
    .velocity_control, .depth_control, .state, .point_valid, .rebased,
    .stable_valid, .audio_cursor_x, .audio_cursor_y, .audio_cursor_z,
    .audio_pitch, .audio_velocity, .audio_depth, .audio_valid,
    .audio_sequence, .audio_timestamp, .frame_output_valid
  );

  task automatic send_frame(input signed [31:0] x, input signed [31:0] y,
                            input signed [31:0] z, input logic valid,
                            input logic edge_flag, input [15:0] seq);
    begin
      @(negedge clk);
      frame_x = x; frame_y = y; frame_z = z; frame_valid = valid;
      left_edge = edge_flag; frame_sequence = seq; frame_timestamp = {16'd0, seq};
      frame_in_valid = 1'b1;
      @(posedge clk); #1;
      frame_in_valid = 1'b0; left_edge = 1'b0;
    end
  endtask

  task automatic wait_done;
    integer i;
    begin
      for (i = 0; i < 900; i = i + 1) begin
        @(posedge clk); #1;
        if (frame_output_valid) i = 900;
      end
    end
  endtask

  initial begin
    integer i;
    logic signed [31:0] pitch_before_z;
    logic signed [31:0] x_before_motion;
    repeat (2) @(posedge clk);
    rst_n = 1'b1;

    send_frame(-32768, 0, 1000, 1'b1, 1'b1, 16'd1);
    wait_done();
    $display("after arm state=%0d point=%b out=%b pitch=%h cursor=%0d,%0d,%0d nx=%0d,%0d,%0d", state, point_valid, frame_output_valid, normalized_pitch, cursor_x, cursor_y, cursor_z, dut.nx, dut.ny, dut.nz);
    if (state !== 2'd1 || !point_valid || rebased || cursor_x !== 32'sd32768)
      $fatal(1, "timed initial arm mismatch state=%0d point=%b rebased=%b x=%0d", state, point_valid, rebased, cursor_x);

    pitch_before_z = normalized_pitch;
    send_frame(-32768, 0, 30000, 1'b1, 1'b0, 16'd2);
    wait_done();
    $display("after z state=%0d point=%b out=%b pitch=%h cursor=%0d,%0d,%0d nx=%0d,%0d,%0d nz=%0d alpha=%0d/%0d depth=%0d", state, point_valid, frame_output_valid, normalized_pitch, cursor_x, cursor_y, cursor_z, dut.nx, dut.ny, dut.nz, dut.nz, dut.alpha_mz, dut.alpha_motion, dut.depth_q);
    if (normalized_pitch !== pitch_before_z)
      $fatal(1, "pure Z-only frame changed pitch before=%0d after=%0d", pitch_before_z, normalized_pitch);

    x_before_motion = cursor_x;
    send_frame(20000, 20000, 1000, 1'b1, 1'b0, 16'd3);
    wait_done();
    if (cursor_x - x_before_motion > 32'sd8192 || x_before_motion - cursor_x > 32'sd8192)
      $fatal(1, "timed slew exceeded one-frame limit before=%0d after=%0d", x_before_motion, cursor_x);

    send_frame(20000, 20000, 1000, 1'b0, 1'b0, 16'd4);
    wait_done();
    if (point_valid || state !== 2'd3)
      $fatal(1, "invalid frame produced a point state=%0d point=%b", state, point_valid);

    // sample_ce may snapshot only the latest stable point and must not alter
    // the frame metadata captured by the cursor engine.
    sample_ce = 1'b1;
    @(posedge clk); #1;
    sample_ce = 1'b0;
    if (audio_valid && audio_sequence !== 16'd3)
      $fatal(1, "audio snapshot sequence mismatch %h", audio_sequence);

    $display("tb_v2_cursor_filter_timed PASS");
    $finish;
  end
endmodule
