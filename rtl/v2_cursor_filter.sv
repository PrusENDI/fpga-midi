// V2 causal cursor filter.  The frame path runs at input-report rate; sample_ce
// only snapshots the last stable point for the audio domain.
module v2_cursor_filter #(
  parameter integer ALPHA_LOW_Q16  = 7864,   // 0.12
  parameter integer ALPHA_HIGH_Q16 = 65536,  // 1.0
  parameter integer Z_LOW          = 4000,
  parameter integer Z_HIGH         = 24000,
  parameter integer Z_ENGAGE       = 30000,
  parameter integer Z_RELEASE      = 36000,
  parameter integer MAX_STEP_Q16   = 4096,
  parameter integer SETTLE_TICKS   = 2
) (
  input logic clk, input logic rst_n,
  input logic frame_in_valid,
  input logic signed [31:0] frame_x, frame_y, frame_z,
  input logic frame_valid, frame_saturated, frame_gap, frame_degraded,
  input logic [7:0] calibration_reason,
  input logic [15:0] frame_sequence,
  input logic [31:0] frame_timestamp,
  input logic left_edge,
  input logic sample_ce,
  output logic signed [31:0] cursor_x, cursor_y, cursor_z,
  output logic [15:0] normalized_pitch,
  output logic [15:0] velocity_control, depth_control,
  output logic [1:0] state,
  output logic point_valid, rebased, stable_valid,
  output logic signed [31:0] audio_cursor_x, audio_cursor_y, audio_cursor_z,
  output logic [15:0] audio_pitch, audio_velocity, audio_depth,
  output logic audio_valid,
  output logic [15:0] audio_sequence,
  output logic [31:0] audio_timestamp
);
  import v2_input_pkg::*;
  localparam logic [1:0] STATE_DISENGAGED = 2'd0;
  localparam logic [1:0] STATE_ENGAGED    = 2'd1;
  localparam logic [1:0] STATE_REBASED    = 2'd2;
  localparam logic [1:0] STATE_DEGRADED   = 2'd3;
  localparam signed [31:0] Q16_ONE = 32'sd65536;
  localparam signed [31:0] LEFT_EDGE_Q16 = 32'sd2048; // 1/32 of full range

  logic signed [31:0] hist_x [0:4], hist_y [0:4], hist_z [0:4];
  logic [2:0] hist_count;
  logic signed [31:0] filt_x, filt_y, filt_z;
  logic signed [31:0] last_raw_x, last_raw_y;
  logic signed [31:0] previous_target_x, previous_target_y;
  logic signed [31:0] anchor_x, anchor_y;
  logic anchor_valid, engaged, have_frame;
  logic [15:0] stable_sequence;
  logic [31:0] stable_timestamp;
  logic signed [31:0] stable_cursor_x, stable_cursor_y, stable_cursor_z;
  logic [15:0] stable_pitch, stable_velocity, stable_depth;
  integer settle_remaining;

  function automatic signed [31:0] median5(
    input signed [31:0] a0, input signed [31:0] a1,
    input signed [31:0] a2, input signed [31:0] a3,
    input signed [31:0] a4, input integer count);
    reg signed [31:0] v [0:4];
    reg signed [31:0] t;
    integer i, j, n;
    begin
      v[0]=a0; v[1]=a1; v[2]=a2; v[3]=a3; v[4]=a4;
      n = (count < 1) ? 1 : ((count > 5) ? 5 : count);
      for (i=0; i<5; i=i+1)
        for (j=i+1; j<5; j=j+1)
          if ((i<n) && (j<n) && (v[j] < v[i])) begin t=v[i]; v[i]=v[j]; v[j]=t; end
      // For an even number of startup samples use the upper middle value,
      // matching the scalar reference's causal median.
      median5 = v[n/2];
    end
  endfunction

  function automatic signed [31:0] map_axis(input signed [31:0] value);
    reg signed [63:0] mapped, quotient;
    begin
      mapped = (value + 64'sd32768) * 64'sd65536;
      if (mapped <= 0) map_axis = 32'sd0;
      else if (mapped >= 64'sd4294901760) map_axis = Q16_ONE;
      else begin quotient = mapped / 64'sd65535; map_axis = quotient[31:0]; end
    end
  endfunction

  function automatic signed [31:0] alpha_for_z(input signed [31:0] value);
    reg signed [63:0] ratio, answer;
    begin
      if (Z_HIGH <= Z_LOW) alpha_for_z = ALPHA_HIGH_Q16;
      else if (value <= Z_LOW) alpha_for_z = ALPHA_HIGH_Q16;
      else if (value >= Z_HIGH) alpha_for_z = ALPHA_LOW_Q16;
      else begin
        ratio = (value - Z_LOW) * 64'sd65536 / (Z_HIGH - Z_LOW);
        answer = ALPHA_HIGH_Q16 - ((ALPHA_HIGH_Q16 - ALPHA_LOW_Q16) * ratio / 64'sd65536);
        if (answer < 0) alpha_for_z = 0;
        else if (answer > 65536) alpha_for_z = 65536;
        else alpha_for_z = answer[31:0];
      end
    end
  endfunction

  function automatic signed [31:0] clamp_step(input signed [63:0] value);
    begin
      if (value > MAX_STEP_Q16) clamp_step = MAX_STEP_Q16;
      else if (value < -MAX_STEP_Q16) clamp_step = -MAX_STEP_Q16;
      else clamp_step = value[31:0];
    end
  endfunction

  function automatic [15:0] q16_u16(input signed [31:0] value);
    begin
      if (value <= 0) q16_u16 = 16'd0;
      else if (value >= 32'sd65535) q16_u16 = 16'hffff;
      else q16_u16 = value[15:0];
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin : filter_proc
    reg signed [31:0] mx, my, mz, tx, ty, a;
    reg signed [31:0] nx, ny, nz;
    reg signed [63:0] dx, dy, dz, sx, sy, prod_x, prod_y, prod_z;
    reg signed [31:0] step_x, step_y, cursor_next_x, cursor_next_y;
    reg signed [31:0] depth, proximity, speed, velocity;
    reg bad, was_hidden, left_arm;
    if (!rst_n) begin
      hist_count <= 0; filt_x <= 0; filt_y <= 0; filt_z <= 0;
      last_raw_x <= 0; last_raw_y <= 0;
      previous_target_x <= 0; previous_target_y <= 0; anchor_x <= 0; anchor_y <= 0;
      anchor_valid <= 0; engaged <= 0; have_frame <= 0; settle_remaining <= 0;
      cursor_x <= 32'sd32768; cursor_y <= 32'sd32768; cursor_z <= 0;
      normalized_pitch <= 16'd32768; velocity_control <= 0; depth_control <= 0;
      state <= STATE_DISENGAGED; point_valid <= 0; rebased <= 0; stable_valid <= 0;
      stable_sequence <= 0; stable_timestamp <= 0;
      stable_cursor_x <= 0; stable_cursor_y <= 0; stable_cursor_z <= 0;
      stable_pitch <= 0; stable_velocity <= 0; stable_depth <= 0;
      audio_cursor_x <= 0; audio_cursor_y <= 0; audio_cursor_z <= 0; audio_pitch <= 0;
      audio_velocity <= 0; audio_depth <= 0; audio_valid <= 0; audio_sequence <= 0; audio_timestamp <= 0;
      hist_x[0]<=0;hist_x[1]<=0;hist_x[2]<=0;hist_x[3]<=0;hist_x[4]<=0;
      hist_y[0]<=0;hist_y[1]<=0;hist_y[2]<=0;hist_y[3]<=0;hist_y[4]<=0;
      hist_z[0]<=0;hist_z[1]<=0;hist_z[2]<=0;hist_z[3]<=0;hist_z[4]<=0;
    end else begin
      rebased <= 1'b0;
      point_valid <= 1'b0;
      if (sample_ce && stable_valid) begin
        audio_cursor_x <= stable_cursor_x; audio_cursor_y <= stable_cursor_y; audio_cursor_z <= stable_cursor_z;
        audio_pitch <= stable_pitch; audio_velocity <= stable_velocity; audio_depth <= stable_depth;
        audio_sequence <= stable_sequence; audio_timestamp <= stable_timestamp; audio_valid <= 1'b1;
      end
      if (frame_in_valid) begin
        bad = !frame_valid || frame_saturated || frame_gap || frame_degraded ||
              ((calibration_reason & (V2_REASON_INVALID|V2_REASON_SATURATED|V2_REASON_GAP|V2_REASON_EPOCH|V2_REASON_PROFILE|V2_REASON_ARITH_SAT)) != 0);
        if (bad) begin
          state <= STATE_DEGRADED;
          point_valid <= 1'b0;
          stable_valid <= stable_valid;
        end else begin
          // Include the current sample in the causal median window.
          if (hist_count < 5) begin
            mx = median5(frame_x,hist_x[0],hist_x[1],hist_x[2],hist_x[3],hist_count+1);
            my = median5(frame_y,hist_y[0],hist_y[1],hist_y[2],hist_y[3],hist_count+1);
            mz = median5(frame_z,hist_z[0],hist_z[1],hist_z[2],hist_z[3],hist_count+1);
          end else begin
            mx = median5(frame_x,hist_x[0],hist_x[1],hist_x[2],hist_x[3],5);
            my = median5(frame_y,hist_y[0],hist_y[1],hist_y[2],hist_y[3],5);
            mz = median5(frame_z,hist_z[0],hist_z[1],hist_z[2],hist_z[3],5);
          end
          tx = map_axis(mx); ty = map_axis(my); a = alpha_for_z(mz);
          if (hist_count == 0) begin nx=tx; ny=ty; nz=mz; end
          else if ((frame_x == last_raw_x) && (frame_y == last_raw_y)) begin
            // Pure Z vectors cannot create a pitch/cursor change.
            dz = mz; dz = dz - filt_z; prod_z = dz * a; nx=filt_x; ny=filt_y; dz = prod_z >>> 16; nz = filt_z + dz[31:0];
          end
          else begin
            dx = tx; dx = dx - filt_x; dy = ty; dy = dy - filt_y; dz = mz; dz = dz - filt_z;
            prod_x = dx * a; prod_y = dy * a; prod_z = dz * a;
            dx = prod_x >>> 16; dy = prod_y >>> 16; dz = prod_z >>> 16;
            nx = filt_x + dx[31:0];
            ny = filt_y + dy[31:0];
            nz = filt_z + dz[31:0];
          end
          filt_x <= nx; filt_y <= ny; filt_z <= nz; last_raw_x <= frame_x; last_raw_y <= frame_y; cursor_z <= nz;
          if (hist_count < 5) hist_count <= hist_count + 1'b1;
          hist_x[0] <= frame_x; hist_y[0] <= frame_y; hist_z[0] <= frame_z;
          if (hist_count >= 1) begin hist_x[1] <= hist_x[0]; hist_y[1] <= hist_y[0]; hist_z[1] <= hist_z[0]; end
          if (hist_count >= 2) begin hist_x[2] <= hist_x[1]; hist_y[2] <= hist_y[1]; hist_z[2] <= hist_z[1]; end
          if (hist_count >= 3) begin hist_x[3] <= hist_x[2]; hist_y[3] <= hist_y[2]; hist_z[3] <= hist_z[2]; end
          if (hist_count >= 4) begin hist_x[4] <= hist_x[3]; hist_y[4] <= hist_y[3]; hist_z[4] <= hist_z[3]; end
          prod_z = nz; prod_z = prod_z - Z_LOW; prod_z = prod_z * 64'sd65536;
          prod_z = prod_z / ((Z_HIGH>Z_LOW) ? (Z_HIGH-Z_LOW) : 1); depth = prod_z[31:0];
          if (depth < 0) depth=0; else if (depth>65536) depth=65536;
          proximity = 65536-depth; speed=0; velocity = 32768 + ((proximity*7)>>>4);
          if (velocity>65536) velocity=65536; velocity_control <= q16_u16(velocity); depth_control <= q16_u16(depth);
          was_hidden = have_frame && !anchor_valid;
          if (engaged && (frame_z > Z_RELEASE)) begin
            engaged <= 1'b0; anchor_valid <= 1'b0; state <= STATE_DISENGAGED;
            point_valid <= 1'b0; stable_valid <= stable_valid;
          end else if (!engaged && (frame_z < Z_ENGAGE) && (was_hidden || left_edge || (tx <= LEFT_EDGE_Q16))) begin
            engaged <= 1'b1; anchor_valid <= 1'b1; anchor_x <= nx; anchor_y <= ny;
            previous_target_x <= nx; previous_target_y <= ny; settle_remaining <= SETTLE_TICKS;
            state <= was_hidden ? STATE_REBASED : STATE_ENGAGED; rebased <= was_hidden; point_valid <= 1'b1;
            if (was_hidden) stable_valid <= 1'b0;
          end else if (engaged) begin
            dx = nx - previous_target_x; dy = ny - previous_target_y;
            sx = dx * a; sy = dy * a; sx = sx >>> 16; sy = sy >>> 16;
            if (settle_remaining > 0) begin sx=0; sy=0; settle_remaining <= settle_remaining-1; end
            step_x = clamp_step(sx); step_y = clamp_step(sy);
            cursor_next_x = cursor_x + step_x; cursor_next_y = cursor_y + step_y;
            if (cursor_next_x < 0) cursor_next_x = 0; else if (cursor_next_x > 65536) cursor_next_x = 65536;
            if (cursor_next_y < 0) cursor_next_y = 0; else if (cursor_next_y > 65536) cursor_next_y = 65536;
            cursor_x <= cursor_next_x; cursor_y <= cursor_next_y;
            previous_target_x <= nx; previous_target_y <= ny; point_valid <= 1'b1; stable_valid <= 1'b1;
            stable_sequence <= frame_sequence; stable_timestamp <= frame_timestamp;
            normalized_pitch <= q16_u16(cursor_next_y);
            if (step_x < 0) speed = -step_x; else speed = step_x;
            if (step_y < 0 && -step_y > speed) speed = -step_y; else if (step_y > speed) speed = step_y;
            velocity = 32768 + ((proximity*7)>>>4) + ((speed*3)>>>4);
            if (velocity > 65536) velocity=65536;
            velocity_control <= q16_u16(velocity);
            stable_cursor_x <= cursor_next_x; stable_cursor_y <= cursor_next_y; stable_cursor_z <= nz;
            stable_pitch <= q16_u16(cursor_next_y); stable_velocity <= q16_u16(velocity); stable_depth <= q16_u16(depth);
            state <= frame_degraded ? STATE_DEGRADED : STATE_ENGAGED;
          end else begin
            state <= STATE_DISENGAGED; point_valid <= 1'b0;
          end
          have_frame <= 1'b1;
        end
      end
    end
  end
endmodule
