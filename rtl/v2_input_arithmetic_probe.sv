// Synthesis preservation probe for the V2 calibration and validity datapath.
// Registered observable outputs keep the arithmetic cones alive in Gowin.
module v2_input_arithmetic_probe (
 input wire clk, input wire rst_n,
 input wire signed [16:0] raw_x, input wire signed [16:0] raw_y, input wire [16:0] raw_z,
 output reg signed [31:0] calibrated_x, output reg signed [31:0] calibrated_y,
 output reg signed [31:0] calibrated_z, output reg valid,
 output reg [7:0] reason, output reg lost, output reg degraded,
 output reg [15:0] gap_count, output reg [31:0] observable_checksum
);
  wire [15:0] seq=16'd0; wire [31:0] ts=32'd0; wire [7:0] epoch=8'd0;
  wire frame=1'b1, xyz=1'b1, sat=1'b0, gap=1'b0, touch=1'b0, presence=1'b1;
  wire signed [31:0] zero=32'sd0, one=32'sd65536;
  wire signed [31:0] lo=-32'sd32768, hi=32'sd32767, zlo=32'sd0, zhi=32'sd65535;
  reg profile_loaded;
  wire profile_shadow_we = rst_n && !profile_loaded;
  wire profile_commit = rst_n && profile_loaded;
  wire [7:0] cal_reason, active_epoch, cal_epoch;
  wire active_profile_valid, cal_valid, cal_saturated, cal_gap;
  wire signed [31:0] cal_x, cal_y, cal_z;
  wire [15:0] cal_seq; wire [31:0] cal_ts; wire cal_touch, cal_presence;
  wire cal_strobe, cal_bundle_valid;
  wire signed [31:0] cal_bundle_x, cal_bundle_y, cal_bundle_z;
  wire [15:0] cal_bundle_seq; wire [31:0] cal_bundle_ts; wire [7:0] cal_bundle_reason;
  wire quality_valid, quality_lost, quality_degraded, quality_note;
  wire [15:0] quality_gap_count; wire [7:0] quality_reason;

  (* keep_hierarchy = "yes" *)
  v2_input_calibration u_calibration (
    .clk,.rst_n,.frame_in_valid(frame),.raw_x,.raw_y,.raw_z,.sequence_id(seq),.timestamp_ticks(ts),
    .valid_xyz(xyz),.saturated(sat),.gap,.calibration_epoch_in(epoch),.touch,.presence,
    .profile_shadow_we,.profile_commit,.shadow_neutral_x(zero),.shadow_neutral_y(zero),
    .shadow_neutral_z(zero),.shadow_coupling_x(zero),.shadow_coupling_y(zero),
    .shadow_gain_x(one),.shadow_gain_y(one),.shadow_gain_z(one),.shadow_ws_x_min(lo),
    .shadow_ws_x_max(hi),.shadow_ws_y_min(lo),.shadow_ws_y_max(hi),.shadow_ws_z_min(zlo),
    .shadow_ws_z_max(zhi),.shadow_epoch(epoch),.calibrated_x(cal_x),.calibrated_y(cal_y),
    .calibrated_z(cal_z),.output_sequence(cal_seq),.output_timestamp_ticks(cal_ts),
    .output_touch(cal_touch),.output_presence(cal_presence),.output_valid(cal_valid),
    .output_saturated(cal_saturated),.output_gap(cal_gap),.output_calibration_epoch(cal_epoch),
    .calibration_reason(cal_reason),.active_epoch,.active_profile_valid,.frame_output_strobe(cal_strobe),
    .frame_calibrated_x(cal_bundle_x),.frame_calibrated_y(cal_bundle_y),.frame_calibrated_z(cal_bundle_z),
    .frame_output_sequence(cal_bundle_seq),.frame_output_timestamp_ticks(cal_bundle_ts),
    .frame_output_reason(cal_bundle_reason),.frame_output_valid(cal_bundle_valid)
  );

  (* keep_hierarchy = "yes" *)
  v2_position_validity u_validity (
    .clk,.rst_n,.frame_in_valid(frame),.valid_xyz(xyz),.saturated(cal_saturated),.gap(cal_gap),
    .sequence_id(cal_seq),.calibration_epoch(cal_epoch),.active_epoch,.active_profile_valid,
    .calibration_reason_in(cal_reason),.frame_valid(quality_valid),.lost(quality_lost),
    .degraded(quality_degraded),.gap_count(quality_gap_count),.calibration_reason(quality_reason),
    .note_permitted(quality_note)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      profile_loaded<=1'b0; calibrated_x<=0; calibrated_y<=0; calibrated_z<=0; valid<=0;
      reason<=0; lost<=0; degraded<=0; gap_count<=0; observable_checksum<=0;
    end else begin
      profile_loaded<=1'b1;
      calibrated_x<=cal_bundle_x; calibrated_y<=cal_bundle_y; calibrated_z<=cal_bundle_z;
      valid<=cal_bundle_valid && quality_valid; reason<=cal_bundle_reason | quality_reason;
      lost<=quality_lost; degraded<=quality_degraded; gap_count<=quality_gap_count;
      observable_checksum<=cal_bundle_x ^ cal_bundle_y ^ cal_bundle_z ^
                           {24'd0,cal_bundle_reason} ^ {16'd0,quality_gap_count};
    end
  end
endmodule
