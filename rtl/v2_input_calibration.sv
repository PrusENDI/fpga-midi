// Fixed-point V2 input calibration. Arithmetic is Q16.16 for coupling and gain.
module v2_input_calibration (
  input logic clk, input logic rst_n,
  input logic frame_in_valid,
  input logic signed [15:0] raw_x, raw_y, raw_z,
  input logic [15:0] sequence_id, input logic [31:0] timestamp_ticks,
  input logic valid_xyz, input logic saturated, input logic gap,
  input logic [7:0] calibration_epoch_in,
  input logic touch, input logic presence,
  input logic profile_shadow_we, input logic profile_commit,
  input logic signed [31:0] shadow_neutral_x, shadow_neutral_y, shadow_neutral_z,
  input logic signed [31:0] shadow_coupling_x, shadow_coupling_y,
  input logic signed [31:0] shadow_gain_x, shadow_gain_y, shadow_gain_z,
  input logic signed [31:0] shadow_ws_x_min, shadow_ws_x_max,
  input logic signed [31:0] shadow_ws_y_min, shadow_ws_y_max,
  input logic signed [31:0] shadow_ws_z_min, shadow_ws_z_max,
  input logic [7:0] shadow_epoch,
  output logic signed [31:0] calibrated_x, calibrated_y, calibrated_z,
  output logic [15:0] output_sequence, output logic [31:0] output_timestamp_ticks,
  output logic output_touch, output_presence,
  output logic output_valid, output_saturated, output_gap,
  output logic [7:0] output_calibration_epoch,
  output logic [7:0] calibration_reason,
  output logic active_profile_valid
);
  localparam signed [31:0] ONE_Q16 = 32'sd65536;
  logic signed [31:0] n_x, n_y, n_z, c_x, c_y, g_x, g_y, g_z;
  logic signed [31:0] ws_x_min, ws_x_max, ws_y_min, ws_y_max, ws_z_min, ws_z_max;
  logic [7:0] epoch_active;
  logic signed [31:0] sn_x, sn_y, sn_z, sc_x, sc_y, sg_x, sg_y, sg_z;
  logic signed [31:0] sw_x_min, sw_x_max, sw_y_min, sw_y_max, sw_z_min, sw_z_max;
  logic [7:0] epoch_shadow;

  function automatic signed [63:0] round_q16(input signed [63:0] value);
    begin
      if (value >= 0) round_q16 = (value + 64'sd32768) >>> 16;
      else round_q16 = -(((-value) + 64'sd32768) >>> 16);
    end
  endfunction
  function automatic signed [31:0] sat32(input signed [63:0] value);
    begin
      if (value > 64'sd2147483647) sat32 = 32'sh7fffffff;
      else if (value < -64'sd2147483648) sat32 = -32'sh80000000;
      else sat32 = value[31:0];
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin : pipeline
    logic signed [63:0] sx, sy, sz;
    logic signed [63:0] dx, dy, dz, qx, qy, qz;
    logic signed [63:0] gx, gy, gz;
    logic signed [31:0] cx, cy, cz;
    logic [7:0] reason;
    logic clamp_seen;
    if (!rst_n) begin
      n_x <= 0; n_y <= 0; n_z <= 0; c_x <= 0; c_y <= 0;
      g_x <= ONE_Q16; g_y <= ONE_Q16; g_z <= ONE_Q16;
      ws_x_min <= -32'sd32768; ws_x_max <= 32'sd32767;
      ws_y_min <= -32'sd32768; ws_y_max <= 32'sd32767;
      ws_z_min <= -32'sd32768; ws_z_max <= 32'sd32767;
      epoch_active <= 0; active_profile_valid <= 1'b1;
      sn_x <= 0; sn_y <= 0; sn_z <= 0; sc_x <= 0; sc_y <= 0;
      sg_x <= ONE_Q16; sg_y <= ONE_Q16; sg_z <= ONE_Q16;
      sw_x_min <= -32'sd32768; sw_x_max <= 32'sd32767;
      sw_y_min <= -32'sd32768; sw_y_max <= 32'sd32767;
      sw_z_min <= -32'sd32768; sw_z_max <= 32'sd32767; epoch_shadow <= 0;
      calibrated_x <= 0; calibrated_y <= 0; calibrated_z <= 0;
      output_sequence <= 0; output_timestamp_ticks <= 0; output_touch <= 0; output_presence <= 0;
      output_valid <= 0; output_saturated <= 0; output_gap <= 0; output_calibration_epoch <= 0;
      calibration_reason <= 0;
    end else begin
      if (profile_shadow_we) begin
        sn_x <= shadow_neutral_x; sn_y <= shadow_neutral_y; sn_z <= shadow_neutral_z;
        sc_x <= shadow_coupling_x; sc_y <= shadow_coupling_y;
        sg_x <= shadow_gain_x; sg_y <= shadow_gain_y; sg_z <= shadow_gain_z;
        sw_x_min <= shadow_ws_x_min; sw_x_max <= shadow_ws_x_max;
        sw_y_min <= shadow_ws_y_min; sw_y_max <= shadow_ws_y_max;
        sw_z_min <= shadow_ws_z_min; sw_z_max <= shadow_ws_z_max; epoch_shadow <= shadow_epoch;
      end
      if (profile_commit) begin
        n_x <= sn_x; n_y <= sn_y; n_z <= sn_z; c_x <= sc_x; c_y <= sc_y;
        g_x <= sg_x; g_y <= sg_y; g_z <= sg_z;
        ws_x_min <= sw_x_min; ws_x_max <= sw_x_max; ws_y_min <= sw_y_min; ws_y_max <= sw_y_max;
        ws_z_min <= sw_z_min; ws_z_max <= sw_z_max; epoch_active <= epoch_shadow;
        active_profile_valid <= 1'b1;
      end
      output_valid <= 1'b0;
      calibration_reason <= 8'd0;
      if (frame_in_valid) begin
        sx = {{48{raw_x[15]}}, raw_x}; sy = {{48{raw_y[15]}}, raw_y}; sz = {{48{raw_z[15]}}, raw_z};
        dx = sx - n_x; dy = sy - n_y; dz = sz - n_z;
        // Coupling subtraction precedes gain, with symmetric nearest-integer rounding.
        qx = dx - round_q16(c_x * dz);
        qy = dy - round_q16(c_y * dz);
        qz = dz;
        gx = round_q16(qx * g_x); gy = round_q16(qy * g_y); gz = round_q16(qz * g_z);
        cx = sat32(gx); cy = sat32(gy); cz = sat32(gz);
        clamp_seen = 1'b0;
        if (cx < ws_x_min) begin cx = ws_x_min; clamp_seen = 1'b1; end else if (cx > ws_x_max) begin cx = ws_x_max; clamp_seen = 1'b1; end
        if (cy < ws_y_min) begin cy = ws_y_min; clamp_seen = 1'b1; end else if (cy > ws_y_max) begin cy = ws_y_max; clamp_seen = 1'b1; end
        if (cz < ws_z_min) begin cz = ws_z_min; clamp_seen = 1'b1; end else if (cz > ws_z_max) begin cz = ws_z_max; clamp_seen = 1'b1; end
        reason = 8'd0;
        if (!valid_xyz) reason = reason | 8'h01;
        if (saturated) reason = reason | 8'h02;
        if (gap) reason = reason | 8'h04;
        if (calibration_epoch_in != epoch_active) reason = reason | 8'h08;
        if (clamp_seen) reason = reason | 8'h10;
        calibrated_x <= cx; calibrated_y <= cy; calibrated_z <= cz;
        output_sequence <= sequence_id; output_timestamp_ticks <= timestamp_ticks;
        output_touch <= touch; output_presence <= presence; output_saturated <= saturated; output_gap <= gap;
        output_calibration_epoch <= calibration_epoch_in;
        calibration_reason <= reason;
        output_valid <= valid_xyz && !saturated && !gap && (calibration_epoch_in == epoch_active);
      end
    end
  end
endmodule


