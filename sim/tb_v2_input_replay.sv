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
  integer fd,scan_count,i; logic signed [16:0] file_x,file_y; logic [16:0] file_z; logic signed [31:0] ex,ey,ez; logic [31:0] ets; logic [15:0] eos,egaps; logic [7:0] ereason,cal_epoch; logic ef,el,ed,en; integer transport,input_xyz_valid,expected_gap,expected_sat,expected_frame_valid,expected_lost,expected_degraded;
  task automatic check_frame(input [15:0] expected_seq,input signed [16:0] expected_x,input signed [16:0] expected_y,input [16:0] expected_z,input integer expected_valid,input integer expected_gap,input integer expected_sat,input [7:0] expected_reason,input [15:0] expected_gap_count,input integer expected_frame_valid,input integer expected_lost,input integer expected_degraded,input integer expected_note);
    begin
      if (!cal_strobe) $fatal(1,"missing aligned output frame=%0d",i);
      if (cal_seq!==expected_seq || latch_seq!==expected_seq || cal_x!==$signed(expected_x) || cal_y!==$signed(expected_y) || cal_z!==$signed(expected_z) || cal_ts!==latch_ts)
        $fatal(1,"bundle mismatch frame=%0d seq=%h/%h latch=%h xyz=%0d,%0d,%0d exp=%0d,%0d,%0d",i,cal_seq,expected_seq,latch_seq,cal_x,cal_y,cal_z,expected_x,expected_y,expected_z);
      if (frame_valid!==expected_frame_valid || lost!==expected_lost || degraded!==expected_degraded || gaps!==expected_gap_count || vreason!==expected_reason || note!==expected_note)
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
      @(posedge clk); #1; report_valid=0;
      @(posedge clk); #1;
      check_frame(eos, expected_frame_valid ? ex[16:0] : 17'sd0, expected_frame_valid ? ey[16:0] : 17'sd0, expected_frame_valid ? ez[16:0] : 17'd0,ef,expected_gap,expected_sat,ereason,egaps,expected_frame_valid,expected_lost,expected_degraded, en);
      // Explicit idle cycle: no output strobe and no status/XYZ mixing.
      @(posedge clk); #1; if(cal_strobe || frame_valid || lost || degraded || note) $fatal(1,"idle leakage frame=%0d",i);
      i=i+1;
    end
    $fclose(fd); if(i<900) $fatal(1,"too few replay frames %0d",i); $display("tb_v2_input_replay PASS frames=%0d",i); $finish;
  end
endmodule
