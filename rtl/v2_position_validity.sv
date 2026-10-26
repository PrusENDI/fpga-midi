module v2_position_validity (
  input logic clk, input logic rst_n,
  input logic frame_in_valid,
  input logic valid_xyz, input logic saturated, input logic gap,
  input logic [15:0] sequence_id,
  input logic [7:0] calibration_epoch, input logic [7:0] active_epoch,
  input logic [7:0] calibration_reason_in,
  output logic frame_valid, output logic lost, output logic degraded,
  output logic [15:0] gap_count, output logic [7:0] calibration_reason,
  output logic note_permitted
);
  logic have_sequence;
  logic [15:0] previous_sequence;
  always_ff @(posedge clk or negedge rst_n) begin : quality
    logic [16:0] delta;
    logic [7:0] reason;
    if (!rst_n) begin
      have_sequence <= 1'b0; previous_sequence <= 16'd0; gap_count <= 16'd0;
      frame_valid <= 1'b0; lost <= 1'b0; degraded <= 1'b0;
      calibration_reason <= 8'd0; note_permitted <= 1'b0;
    end else begin
      frame_valid <= 1'b0; lost <= 1'b0; degraded <= 1'b0;
      note_permitted <= 1'b0; calibration_reason <= 8'd0;
      if (frame_in_valid) begin
        reason = calibration_reason_in;
        delta = {1'b0, sequence_id} - {1'b0, previous_sequence};
        if (have_sequence && (delta > 17'd1)) begin
          reason = reason | 8'h04;
          if (gap_count != 16'hffff) gap_count <= gap_count + delta[15:0] - 16'd1;
        end
        if (gap && (!have_sequence || delta <= 17'd1)) begin
          reason = reason | 8'h04;
          if (gap_count != 16'hffff) gap_count <= gap_count + 16'd1;
        end
        if (!valid_xyz) reason = reason | 8'h01;
        if (saturated) reason = reason | 8'h02;
        if (calibration_epoch != active_epoch) reason = reason | 8'h08;
        calibration_reason <= reason;
        lost <= |(reason & 8'h04);
        degraded <= |(reason & 8'h3c);
        frame_valid <= !(|(reason & 8'h0f));
        note_permitted <= !(|(reason & 8'h0f));
        previous_sequence <= sequence_id;
        have_sequence <= 1'b1;
      end
    end
  end
endmodule


