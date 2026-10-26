module v2_input_arithmetic_probe (
 input wire clk, input wire rst_n, input wire signed [16:0] raw_x, input wire signed [16:0] raw_y, input wire [16:0] raw_z,
 output wire signed [31:0] calibrated_x, output wire signed [31:0] calibrated_y, output wire signed [31:0] calibrated_z,
 output wire valid
);
  wire [15:0] seq=0; wire [31:0] ts=0; wire [7:0] epoch=0; wire frame=1, xyz=1, sat=0, gap=0, touch=0, presence=1;
  wire signed [31:0] zero=0, one=32'sd65536, lo=-32'sd32768, hi=32'sd32767, zlo=0, zhi=32'sd65535;
  wire [7:0] reason, active_epoch; wire active_profile_valid;
  (* keep = "true" *) wire signed [31:0] keep_x=calibrated_x, keep_y=calibrated_y, keep_z=calibrated_z;
  (* keep = "true" *) wire keep_valid=valid;
  v2_input_calibration u(.clk,.rst_n,.frame_in_valid(frame),.raw_x,.raw_y,.raw_z,.sequence_id(seq),.timestamp_ticks(ts),.valid_xyz(xyz),.saturated(sat),.gap,.calibration_epoch_in(epoch),.touch,.presence,.profile_shadow_we(1'b0),.profile_commit(1'b0),.shadow_neutral_x(zero),.shadow_neutral_y(zero),.shadow_neutral_z(zero),.shadow_coupling_x(zero),.shadow_coupling_y(zero),.shadow_gain_x(one),.shadow_gain_y(one),.shadow_gain_z(one),.shadow_ws_x_min(lo),.shadow_ws_x_max(hi),.shadow_ws_y_min(lo),.shadow_ws_y_max(hi),.shadow_ws_z_min(zlo),.shadow_ws_z_max(zhi),.shadow_epoch(epoch),.calibrated_x,.calibrated_y,.calibrated_z,.output_sequence(),.output_timestamp_ticks(),.output_touch(),.output_presence(),.output_valid(valid),.output_saturated(),.output_gap(),.output_calibration_epoch(),.calibration_reason(reason),.active_epoch,.active_profile_valid);
endmodule
