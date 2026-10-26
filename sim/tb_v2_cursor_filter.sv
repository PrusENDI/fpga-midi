`timescale 1ns/1ps
module tb_v2_cursor_filter;
  logic clk=0, rst_n=0, frame_in_valid=0, sample_ce=0;
  logic signed [31:0] frame_x=0,frame_y=0,frame_z=0;
  logic frame_valid=1, frame_saturated=0, frame_gap=0, frame_degraded=0, left_edge=0;
  logic [7:0] calibration_reason=0; logic [15:0] frame_sequence=0; logic [31:0] frame_timestamp=0;
  logic signed [31:0] cursor_x,cursor_y,cursor_z; logic [15:0] normalized_pitch;
  logic [15:0] velocity_control,depth_control; logic [1:0] state;
  logic point_valid,rebased,stable_valid; logic signed [31:0] audio_cursor_x,audio_cursor_y,audio_cursor_z;
  logic [15:0] audio_pitch,audio_velocity,audio_depth; logic audio_valid; logic [15:0] audio_sequence; logic [31:0] audio_timestamp;
  logic signed [31:0] median_cursor_x, median_cursor_y, median_cursor_z;
  logic [15:0] median_pitch, median_velocity, median_depth; logic [1:0] median_state;
  logic median_point_valid, median_rebased, median_stable_valid, median_audio_valid;
  logic signed [31:0] median_audio_x, median_audio_y, median_audio_z;
  logic [15:0] median_audio_pitch, median_audio_velocity, median_audio_depth, median_audio_sequence;
  logic [31:0] median_audio_timestamp;
  localparam [1:0] DISENGAGED=0, ENGAGED=1, REBASED=2, DEGRADED=3;
  always #5 clk=~clk;
  v2_cursor_filter #(.MAX_STEP_Q16(16'd8192),.SETTLE_TICKS(0)) dut(
    .clk,.rst_n,.frame_in_valid,.frame_x,.frame_y,.frame_z,.frame_valid,.frame_saturated,.frame_gap,.frame_degraded,
    .calibration_reason,.frame_sequence,.frame_timestamp,.left_edge,.sample_ce,
    .cursor_x,.cursor_y,.cursor_z,.normalized_pitch,.velocity_control,.depth_control,.state,
    .point_valid,.rebased,.stable_valid,.audio_cursor_x,.audio_cursor_y,.audio_cursor_z,
    .audio_pitch,.audio_velocity,.audio_depth,.audio_valid,.audio_sequence,.audio_timestamp);
  v2_cursor_filter #(.MAX_STEP_Q16(32'd65536),.SETTLE_TICKS(0)) median_dut(
    .clk,.rst_n,.frame_in_valid,.frame_x,.frame_y,.frame_z,.frame_valid,.frame_saturated,.frame_gap,.frame_degraded,
    .calibration_reason,.frame_sequence,.frame_timestamp,.left_edge,.sample_ce,
    .cursor_x(median_cursor_x),.cursor_y(median_cursor_y),.cursor_z(median_cursor_z),.normalized_pitch(median_pitch),
    .velocity_control(median_velocity),.depth_control(median_depth),.state(median_state),
    .point_valid(median_point_valid),.rebased(median_rebased),.stable_valid(median_stable_valid),
    .audio_cursor_x(median_audio_x),.audio_cursor_y(median_audio_y),.audio_cursor_z(median_audio_z),
    .audio_pitch(median_audio_pitch),.audio_velocity(median_audio_velocity),.audio_depth(median_audio_depth),
    .audio_valid(median_audio_valid),.audio_sequence(median_audio_sequence),.audio_timestamp(median_audio_timestamp));
  task automatic send(input signed [31:0] x,y,z,input logic edge_flag,input [15:0] seq,input [31:0] ts);
    begin @(negedge clk); frame_x=x;frame_y=y;frame_z=z;left_edge=edge_flag;frame_sequence=seq;frame_timestamp=ts;frame_in_valid=1;
      @(posedge clk); #1; @(negedge clk); frame_in_valid=0;left_edge=0; end
  endtask
  initial begin
    reg signed [31:0] held_x, held_y;
    repeat(2) @(posedge clk); rst_n=1;
    send(-32768,0,1000,1,0,32'd100);
    if(state!==ENGAGED || rebased || cursor_x!==32'sd32768) $fatal(1,"initial arm state=%0d rebased=%b x=%0d",state,rebased,cursor_x);
    send(32767,32767,1000,0,1,32'd200);
    if(state!==ENGAGED || cursor_x-32'sd32768 > 32'sd8192 || cursor_y-32'sd32768 > 32'sd8192) $fatal(1,"slew state=%0d x=%0d y=%0d",state,cursor_x,cursor_y);
    if(normalized_pitch!==cursor_y || velocity_control!==16'd62976) $fatal(1,"next pitch/control pitch=%0d cursor_y=%0d velocity=%0d",normalized_pitch,cursor_y,velocity_control);
    held_x=cursor_x; held_y=cursor_y;
    sample_ce=1; @(posedge clk); #1; sample_ce=0;
    if(!audio_valid || audio_timestamp!==32'd200 || audio_sequence!==16'd1) $fatal(1,"audio snapshot");
    send(20000,-20000,40000,0,2,32'd300);
    if(state!==DISENGAGED || cursor_x!==held_x || cursor_y!==held_y) $fatal(1,"high z freeze state=%0d x=%0d/%0d",state,cursor_x,held_x);
    frame_sequence=16'd99; frame_timestamp=32'd9999; sample_ce=1; @(posedge clk); #1; sample_ce=0;
    if(audio_sequence!==16'd1 || audio_timestamp!==32'd200 || audio_cursor_x!==32'sd40960 || audio_velocity!==16'd62976)
      $fatal(1,"sample_ce published non-stable point seq=%0d ts=%0d x=%0d vel=%0d",audio_sequence,audio_timestamp,audio_cursor_x,audio_velocity);
    send(20000,-20000,20000,0,3,32'd400);
    if(state!==REBASED || !rebased || cursor_x!==held_x || cursor_y!==held_y) $fatal(1,"rebase state=%0d rebased=%b",state,rebased);
    if(stable_valid) $fatal(1,"rebase published stable point");
    frame_sequence=16'd100; frame_timestamp=32'd10000; sample_ce=1; @(posedge clk); #1; sample_ce=0;
    if(audio_sequence!==16'd1 || audio_timestamp!==32'd200) $fatal(1,"rebase changed latest stable metadata");
    send(21000,-19000,20000,0,4,32'd500);
    if(state!==ENGAGED || rebased) $fatal(1,"rebase pulse state=%0d rebased=%b",state,rebased);
    held_x=cursor_x; held_y=cursor_y;
    frame_valid=0; calibration_reason=8'h01; send(30000,30000,1000,0,5,32'd600);
    if(state!==DEGRADED || cursor_x!==held_x || cursor_y!==held_y) $fatal(1,"invalid changed cursor");
    frame_valid=1; calibration_reason=0; frame_degraded=1; send(30000,30000,1000,0,6,32'd650);
    if(state!==DEGRADED || cursor_x!==held_x || cursor_y!==held_y) $fatal(1,"degraded frame changed cursor");
    frame_degraded=0;
    send(21000,-19000,25000,0,7,32'd700); if(normalized_pitch!==cursor_y[15:0]) $fatal(1,"pitch mismatch");
    // After five prior samples, the full median window must be current + latest four.
    rst_n=0; repeat(2) @(posedge clk); rst_n=1;
    send(-32768,0,1000,1,0,32'd1000); send(-20000,0,1000,0,1,32'd1100);
    send(-10000,0,1000,0,2,32'd1200); send(0,0,1000,0,3,32'd1300);
    send(10000,0,1000,0,4,32'd1400); send(20000,0,1000,0,5,32'd1500);
    if(median_cursor_x!==32'sd65536) $fatal(1,"latest-5 median stale cursor_x=%0d",median_cursor_x);
    rst_n=0; repeat(2) @(posedge clk); rst_n=1;
    send(-32768,-32768,1000,1,0,32'd2000); send(32767,32767,1000,0,1,32'd2100);
    if(median_pitch!==16'hffff) $fatal(1,"pitch did not saturate pitch=%0d",median_pitch);
    $display("tb_v2_cursor_filter PASS"); $finish;
  end
endmodule
