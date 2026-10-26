`timescale 1ns/1ps
module tb_v2_input_replay;
  import v2_input_pkg::*;
  logic clk=0, rst_n=0, report_valid=0, xyz_valid=0, report_error=0;
  logic [15:0] sensor_x,sensor_y,sensor_z; logic [7:0] gesture=0; logic [31:0] touch_info=0; logic touch_valid=0; logic v2_saturated_in=0, v2_sequence_valid=0; logic [15:0] v2_sequence_in=0;
  wire input_valid, xyz_valid_latched; wire [15:0] x_latched,y_latched,z_latched; wire [7:0] gesture_latched;
  wire report_valid_latched,report_error_latched,touch_valid_latched; wire [31:0] touch_info_latched;
  wire [15:0] latch_seq; wire [31:0] latch_ts; wire signed [16:0] latch_x,latch_y; wire [16:0] latch_z;
  wire latch_strobe,latch_gap,latch_sat,latch_touch,latch_presence,latch_xyz,latch_error,latch_touch_field; wire [7:0] latch_epoch; wire [31:0] latch_touch_info;
  mgc3130_input_latch latch(.clk,.rst_n,.report_valid,.xyz_valid,.report_error,.x_position(sensor_x),.y_position(sensor_y),.z_position(sensor_z),.gesture_code(gesture),.input_valid,.xyz_valid_latched,.x_latched,.y_latched,.z_latched,.gesture_latched,.touch_info,.touch_valid,.report_valid_latched,.report_error_latched,.touch_valid_latched,.touch_info_latched,.v2_sequence(latch_seq),.v2_timestamp_ticks(latch_ts),.v2_raw_x(latch_x),.v2_raw_y(latch_y),.v2_raw_z(latch_z),.v2_frame_valid(latch_strobe),.v2_gap(latch_gap),.v2_saturated(latch_sat),.v2_calibration_epoch(latch_epoch),.v2_touch(latch_touch),.v2_presence(latch_presence),.v2_xyz_valid(latch_xyz),.v2_report_error(latch_error),.v2_touch_field_valid(latch_touch_field),.v2_touch_info(latch_touch_info),.v2_saturated_in,.v2_sequence_valid,.v2_sequence_in);
  logic signed [31:0] x,y,z; logic [15:0] os; logic [31:0] ot; logic ov,osat,og,otouch,opres; logic [7:0] oe,reason,active_epoch; logic active_profile_valid;
  logic cal_strobe,cal_valid; logic signed [31:0] cal_x,cal_y,cal_z; logic [15:0] cal_seq; logic [31:0] cal_ts; logic [7:0] cal_reason;
  logic frame_valid,lost,degraded,note; logic [15:0] gaps; logic [7:0] vreason;
  logic profile_shadow_we=0,profile_commit=0; logic signed [31:0] snx=0,sny=0,snz=0,scx=0,scy=0,sgx=65536,sgy=65536,sgz=65536;
  logic signed [31:0] wxmin=-32768,wxmax=32767,wymin=-32768,wymax=32767,wzmin=0,wzmax=65535; logic [7:0] shepoch=0;
  v2_input_calibration cal(.clk,.rst_n,.frame_in_valid(latch_strobe),.raw_x(latch_x),.raw_y(latch_y),.raw_z(latch_z),.sequence_id(latch_seq),.timestamp_ticks(latch_ts),.valid_xyz(latch_xyz),.saturated(latch_sat),.gap(latch_gap),.calibration_epoch_in(latch_epoch),.touch(latch_touch),.presence(latch_presence),.profile_shadow_we,.profile_commit,.shadow_neutral_x(snx),.shadow_neutral_y(sny),.shadow_neutral_z(snz),.shadow_coupling_x(scx),.shadow_coupling_y(scy),.shadow_gain_x(sgx),.shadow_gain_y(sgy),.shadow_gain_z(sgz),.shadow_ws_x_min(wxmin),.shadow_ws_x_max(wxmax),.shadow_ws_y_min(wymin),.shadow_ws_y_max(wymax),.shadow_ws_z_min(wzmin),.shadow_ws_z_max(wzmax),.shadow_epoch(shepoch),.calibrated_x(x),.calibrated_y(y),.calibrated_z(z),.output_sequence(os),.output_timestamp_ticks(ot),.output_touch(otouch),.output_presence(opres),.output_valid(ov),.output_saturated(osat),.output_gap(og),.output_calibration_epoch(oe),.calibration_reason(reason),.active_epoch,.active_profile_valid,.frame_output_strobe(cal_strobe),.frame_calibrated_x(cal_x),.frame_calibrated_y(cal_y),.frame_calibrated_z(cal_z),.frame_output_sequence(cal_seq),.frame_output_timestamp_ticks(cal_ts),.frame_output_reason(cal_reason),.frame_output_valid(cal_valid));
  v2_position_validity val(.clk,.rst_n,.frame_in_valid(latch_strobe),.valid_xyz(latch_xyz),.saturated(latch_sat),.gap(latch_gap),.sequence_id(latch_seq),.calibration_epoch(latch_epoch),.active_epoch,.active_profile_valid,.calibration_reason_in(reason),.frame_valid,.lost,.degraded,.gap_count(gaps),.calibration_reason(vreason),.note_permitted(note));
  always #5 clk=~clk;
  integer fd,scan_count,i; logic signed [16:0] file_x,file_y; logic [16:0] file_z; logic signed [31:0] ex,ey,ez; logic [31:0] ets; logic [15:0] eos,egaps; logic [7:0] ereason,cal_epoch; logic ef,el,ed,en; integer transport,input_xyz_valid,expected_gap,expected_sat,expected_frame_valid,expected_lost,expected_degraded; logic [31:0] free_timestamp_model=0,expected_latch_timestamp;
  logic [15:0] sampled_latch_seq; logic [31:0] sampled_latch_ts; logic signed [16:0] sampled_latch_x,sampled_latch_y; logic [16:0] sampled_latch_z;
  logic sampled_latch_gap,sampled_latch_sat,sampled_latch_xyz,sampled_latch_error;
  logic [15:0] adjacent_seq1,adjacent_seq2; logic [31:0] adjacent_ts1,adjacent_ts2; logic signed [16:0] adjacent_x1,adjacent_y1,adjacent_x2,adjacent_y2; logic [16:0] adjacent_z1,adjacent_z2; logic adjacent_gap1,adjacent_gap2,adjacent_sat1,adjacent_sat2,adjacent_xyz1,adjacent_xyz2,adjacent_error1,adjacent_error2;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) free_timestamp_model <= 32'd0;
    else free_timestamp_model <= free_timestamp_model + 1'b1;
  end
  task automatic check_frame(input [15:0] expected_seq,input [31:0] expected_timestamp,input signed [16:0] expected_raw_x,input signed [16:0] expected_raw_y,input [16:0] expected_raw_z,input signed [31:0] expected_x,input signed [31:0] expected_y,input signed [31:0] expected_z,input integer expected_valid,input integer expected_gap,input integer expected_sat,input [7:0] expected_reason,input [15:0] expected_gap_count,input integer expected_frame_valid,input integer expected_lost,input integer expected_degraded,input integer expected_note);
    begin
      if (!cal_strobe) $fatal(1,"missing aligned output frame=%0d",i);
      if (cal_seq!==expected_seq || sampled_latch_seq!==expected_seq || cal_ts!==expected_timestamp || sampled_latch_ts!==expected_timestamp ||
          sampled_latch_gap!==expected_gap || sampled_latch_sat!==expected_sat || sampled_latch_error!==expected_gap || sampled_latch_xyz!==expected_valid ||
          sampled_latch_x!==expected_raw_x || sampled_latch_y!==expected_raw_y || sampled_latch_z!==expected_raw_z ||
          cal_x!==expected_x || cal_y!==expected_y || cal_z!==expected_z)
        $fatal(1,"bundle mismatch frame=%0d seq cal/latch/exp=%h/%h/%h ts cal/latch/exp=%h/%h/%h raw latch/exp=%0d,%0d,%0d/%0d,%0d,%0d flags gap/sat/err/xyz=%b/%b/%b/%b exp=%b/%b/%b/%b xyz=%0d,%0d,%0d exp=%0d,%0d,%0d",i,cal_seq,sampled_latch_seq,expected_seq,cal_ts,sampled_latch_ts,expected_timestamp,sampled_latch_x,sampled_latch_y,sampled_latch_z,expected_raw_x,expected_raw_y,expected_raw_z,sampled_latch_gap,sampled_latch_sat,sampled_latch_error,sampled_latch_xyz,expected_gap,expected_sat,expected_gap,expected_valid,cal_x,cal_y,cal_z,expected_x,expected_y,expected_z);
      if (cal_reason!==vreason || cal_reason!==expected_reason || cal_valid!==frame_valid || cal_valid!==expected_frame_valid ||
          frame_valid!==expected_frame_valid || lost!==expected_lost || degraded!==expected_degraded || gaps!==expected_gap_count || note!==expected_note)
        $fatal(1,"validity mismatch frame=%0d fv=%b/%b lost=%b/%b deg=%b/%b gaps=%h/%h reason=%h/%h note=%b/%b",i,frame_valid,expected_frame_valid,lost,expected_lost,degraded,expected_degraded,gaps,expected_gap_count,vreason,expected_reason,note,expected_note);
      if (!expected_frame_valid && ((cal_x!==0)||(cal_y!==0)||(cal_z!==0))) $fatal(1,"invalid output nonzero frame=%0d",i);
    end
  endtask
  initial begin
    rst_n=0; #2; rst_n=1; repeat(2) @(posedge clk);
    @(negedge clk); profile_shadow_we=1; @(posedge clk); #1; @(negedge clk); profile_shadow_we=0; profile_commit=1; @(posedge clk); #1; profile_commit=0;
    fd=$fopen("../../tools/testdata/v2_input/replay_fast_01.vec","r"); if(!fd) $fatal(1,"vector open failed"); i=0;
    while(!$feof(fd)) begin
      scan_count=$fscanf(fd,"%h %h %h %h %h %d %d %d %d %h %h %h %h %d %d %d %h %h %d\n",eos,ets,file_x,file_y,file_z,transport,input_xyz_valid,expected_sat,expected_gap,cal_epoch,ex,ey,ez,expected_frame_valid,expected_lost,expected_degraded,egaps,ereason,en);
      if(scan_count<19) break;
      @(negedge clk); sensor_x=file_x+17'sd32768; sensor_y=file_y+17'sd32768; sensor_z=file_z[15:0]; xyz_valid=input_xyz_valid; v2_saturated_in=expected_sat; v2_sequence_valid=1'b1; v2_sequence_in=eos; report_error=expected_gap; report_valid=1;
      expected_latch_timestamp=free_timestamp_model;
      @(posedge clk); #1;
      sampled_latch_seq=latch_seq; sampled_latch_ts=latch_ts; sampled_latch_x=latch_x; sampled_latch_y=latch_y; sampled_latch_z=latch_z;
      sampled_latch_gap=latch_gap; sampled_latch_sat=latch_sat; sampled_latch_error=latch_error; sampled_latch_xyz=latch_xyz;
      report_valid=0;
      @(posedge clk); #1;
      check_frame(eos,expected_latch_timestamp,file_x,file_y,file_z,expected_frame_valid ? ex : 32'sd0,expected_frame_valid ? ey : 32'sd0,expected_frame_valid ? ez : 32'sd0,input_xyz_valid,expected_gap,expected_sat,ereason,egaps,expected_frame_valid,expected_lost,expected_degraded,en);
      // Explicit idle cycle: no output strobe and no status/XYZ mixing.
      @(posedge clk); #1; if(cal_strobe || frame_valid || lost || degraded || note) $fatal(1,"idle leakage frame=%0d",i);
      i=i+1;
    end
    $fclose(fd); if(i<900) $fatal(1,"too few replay frames %0d",i);
    // Adjacent A/B transport check: report_valid stays high across two
    // consecutive report edges, so the first bundle must not be overwritten
    // by the second latch sample.
    @(negedge clk); sensor_x=16'h8000; sensor_y=16'h8000; sensor_z=16'h9c40; xyz_valid=1; v2_saturated_in=0; v2_sequence_valid=1; v2_sequence_in=16'h0001; report_error=0; report_valid=1; adjacent_ts1=free_timestamp_model;
    @(posedge clk); #1; adjacent_seq1=latch_seq; adjacent_x1=latch_x; adjacent_y1=latch_y; adjacent_z1=latch_z; adjacent_gap1=latch_gap; adjacent_sat1=latch_sat; adjacent_xyz1=latch_xyz; adjacent_error1=latch_error;
    @(negedge clk); sensor_x=16'h7fff; sensor_y=16'h8001; sensor_z=16'h9c41; v2_sequence_in=16'h0002; adjacent_ts2=free_timestamp_model;
    @(posedge clk); #1; adjacent_seq2=latch_seq; adjacent_x2=latch_x; adjacent_y2=latch_y; adjacent_z2=latch_z; adjacent_gap2=latch_gap; adjacent_sat2=latch_sat; adjacent_xyz2=latch_xyz; adjacent_error2=latch_error;
    sampled_latch_seq=adjacent_seq1; sampled_latch_ts=adjacent_ts1; sampled_latch_x=adjacent_x1; sampled_latch_y=adjacent_y1; sampled_latch_z=adjacent_z1; sampled_latch_gap=adjacent_gap1; sampled_latch_sat=adjacent_sat1; sampled_latch_xyz=adjacent_xyz1; sampled_latch_error=adjacent_error1;
    check_frame(16'h0001,adjacent_ts1,17'sd0,17'sd0,17'd40000,32'sd0,32'sd0,32'sd40000,1,0,0,8'd0,16'hfc31,1,0,0,1);
    report_valid=0;
    @(posedge clk); #1;
    sampled_latch_seq=adjacent_seq2; sampled_latch_ts=adjacent_ts2; sampled_latch_x=adjacent_x2; sampled_latch_y=adjacent_y2; sampled_latch_z=adjacent_z2; sampled_latch_gap=adjacent_gap2; sampled_latch_sat=adjacent_sat2; sampled_latch_xyz=adjacent_xyz2; sampled_latch_error=adjacent_error2;
    check_frame(16'h0002,adjacent_ts2,-17'sd1,17'sd1,17'd40001,-32'sd1,32'sd1,32'sd40001,1,0,0,8'd0,16'hfc31,1,0,0,1);
    @(posedge clk); #1; if (cal_strobe || frame_valid || lost || degraded || note) $fatal(1,"adjacent idle leakage");
    $display("tb_v2_input_replay PASS frames=%0d adjacent=A/B",i); $finish;
  end
endmodule
