`timescale 1ns/1ps
// File-driven Task 4 replay: real latch -> calibration -> validity -> cursor.
module tb_v2_cursor_replay;
  import v2_input_pkg::*;
  logic clk=0, rst_n=0, report_valid=0, xyz_valid=0, report_error=0;
  logic [15:0] sensor_x,sensor_y,sensor_z; logic [15:0] seq_in; logic sat_in=0;
  wire [15:0] lseq; wire [31:0] lts; wire signed [16:0] lraw_x,lraw_y; wire [16:0] lraw_z;
  wire lstrobe,lgap,lsat,lxyz,lerr,ltouch,lpres; wire [7:0] lepoch; wire [31:0] ltinfo;
  mgc3130_input_latch latch(.clk,.rst_n,.report_valid,.xyz_valid,.report_error,.x_position(sensor_x),.y_position(sensor_y),.z_position(sensor_z),.gesture_code(8'd0),.input_valid(),.xyz_valid_latched(),.x_latched(),.y_latched(),.z_latched(),.gesture_latched(),.touch_info(32'd0),.touch_valid(1'b0),.report_valid_latched(),.report_error_latched(),.touch_valid_latched(),.touch_info_latched(),.v2_sequence(lseq),.v2_timestamp_ticks(lts),.v2_raw_x(lraw_x),.v2_raw_y(lraw_y),.v2_raw_z(lraw_z),.v2_frame_valid(lstrobe),.v2_gap(lgap),.v2_saturated(lsat),.v2_calibration_epoch(lepoch),.v2_touch(ltouch),.v2_presence(lpres),.v2_xyz_valid(lxyz),.v2_report_error(lerr),.v2_touch_field_valid(),.v2_touch_info(),.v2_saturated_in(sat_in),.v2_sequence_valid(1'b1),.v2_sequence_in(seq_in));
  logic signed [16:0] q0_x,q0_y; logic [16:0] q0_z; logic [15:0] q0_seq; logic [31:0] q0_ts; logic q0_valid,q1_valid,q0_xyz,q0_gap,q0_sat; logic signed [16:0] q1_x,q1_y; logic [16:0] q1_z; logic [15:0] q1_seq; logic [31:0] q1_ts; logic q1_xyz,q1_gap,q1_sat;
  wire cal_frame_strobe=q0_valid;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin q0_valid<=0; q1_valid<=0; end
    else if (q0_valid) begin
      if (q1_valid) begin q0_x<=q1_x; q0_y<=q1_y; q0_z<=q1_z; q0_seq<=q1_seq; q0_ts<=q1_ts; q0_xyz<=q1_xyz; q0_gap<=q1_gap; q0_sat<=q1_sat; q0_valid<=1'b1; q1_valid<=1'b0; end
      else if (lstrobe) begin q0_x<=lraw_x; q0_y<=lraw_y; q0_z<=lraw_z; q0_seq<=lseq; q0_ts<=lts; q0_xyz<=lxyz; q0_gap<=lgap; q0_sat<=lsat; q0_valid<=1'b1; end
      else q0_valid<=1'b0;
    end else if (lstrobe) begin q0_x<=lraw_x; q0_y<=lraw_y; q0_z<=lraw_z; q0_seq<=lseq; q0_ts<=lts; q0_xyz<=lxyz; q0_gap<=lgap; q0_sat<=lsat; q0_valid<=1'b1; end
  end
  logic signed [31:0] cx,cy,cz; logic [15:0] cseq; logic [31:0] cts; logic cvalid,csat,cgap; logic [7:0] creason,cepoch; logic cstrobe;
  logic signed [31:0] shadow_zero=0,shadow_one=65536,shadow_lo=-32768,shadow_hi=32767,shadow_zlo=0,shadow_zhi=65535; logic profile_we=0,profile_commit=0;
  logic active_profile; logic [7:0] active_epoch;
  v2_input_calibration cal(.clk,.rst_n,.frame_in_valid(cal_frame_strobe),.raw_x(q0_x),.raw_y(q0_y),.raw_z(q0_z),.sequence_id(q0_seq),.timestamp_ticks(q0_ts),.valid_xyz(q0_xyz),.saturated(q0_sat),.gap(q0_gap),.calibration_epoch_in(8'd0),.touch(1'b0),.presence(q0_xyz),.profile_shadow_we(profile_we),.profile_commit,.shadow_neutral_x(shadow_zero),.shadow_neutral_y(shadow_zero),.shadow_neutral_z(shadow_zero),.shadow_coupling_x(shadow_zero),.shadow_coupling_y(shadow_zero),.shadow_gain_x(shadow_one),.shadow_gain_y(shadow_one),.shadow_gain_z(shadow_one),.shadow_ws_x_min(shadow_lo),.shadow_ws_x_max(shadow_hi),.shadow_ws_y_min(shadow_lo),.shadow_ws_y_max(shadow_hi),.shadow_ws_z_min(shadow_zlo),.shadow_ws_z_max(shadow_zhi),.shadow_epoch(8'd0),.calibrated_x(),.calibrated_y(),.calibrated_z(),.output_sequence(),.output_timestamp_ticks(),.output_touch(),.output_presence(),.output_valid(),.output_saturated(),.output_gap(),.output_calibration_epoch(),.calibration_reason(),.active_epoch,.active_profile_valid(active_profile),.frame_output_strobe(cstrobe),.frame_calibrated_x(cx),.frame_calibrated_y(cy),.frame_calibrated_z(cz),.frame_output_sequence(cseq),.frame_output_timestamp_ticks(cts),.frame_output_reason(creason),.frame_output_valid(cvalid));
  wire vvalid,vlost,vdegraded,vnote; wire [15:0] vgapcount; wire [7:0] vreason;
  v2_position_validity val(.clk,.rst_n,.frame_in_valid(cstrobe),.valid_xyz(cvalid),.saturated(q0_sat),.gap(q0_gap),.sequence_id(cseq),.calibration_epoch(8'd0),.active_epoch,.active_profile_valid(active_profile),.calibration_reason_in(creason),.frame_valid(vvalid),.lost(vlost),.degraded(vdegraded),.gap_count(vgapcount),.calibration_reason(vreason),.note_permitted(vnote));
  logic latch_sat_aligned,latch_gap_aligned;
  logic cursor_strobe,validity_strobe;
  logic cursor_valid_aligned,cursor_degraded_aligned,cursor_sat_aligned,cursor_gap_aligned;
  logic [7:0] cursor_reason_aligned;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      latch_sat_aligned<=0; latch_gap_aligned<=0; cursor_strobe<=0; validity_strobe<=0;
      cursor_valid_aligned<=0; cursor_degraded_aligned<=0; cursor_sat_aligned<=0; cursor_gap_aligned<=0; cursor_reason_aligned<=0;
    end else begin
      if (cal_frame_strobe) begin latch_sat_aligned<=q0_sat; latch_gap_aligned<=q0_gap; end
      cursor_strobe<=cstrobe;
      validity_strobe<=cursor_strobe;
      // At this edge v2_position_validity has the result for the same
      // cstrobe bundle; the cursor consumes this registered copy next edge.
      if (cursor_strobe) begin
        cursor_valid_aligned<=vvalid;
        cursor_degraded_aligned<=vdegraded;
        cursor_sat_aligned<=latch_sat_aligned;
        cursor_gap_aligned<=latch_gap_aligned;
        cursor_reason_aligned<=vreason;
      end
    end
  end
  logic sample_ce; logic left_edge;
  wire signed [31:0] ox,oy,oz; wire [15:0] opitch,ovel,odepth; wire [1:0] ostate; wire opoint,orebased,ostable;
  wire signed [31:0] ax,ay,az; wire [15:0] apitch,avel,adepth,aseq; wire [31:0] ats; wire aval;
  v2_cursor_filter #(.SETTLE_TICKS(2)) cursor(.clk,.rst_n,.frame_in_valid(validity_strobe),.frame_x(cx),.frame_y(cy),.frame_z(cz),.frame_valid(cursor_valid_aligned),.frame_saturated(cursor_sat_aligned),.frame_gap(cursor_gap_aligned),.frame_degraded(cursor_degraded_aligned),.calibration_reason(cursor_reason_aligned),.frame_sequence(cseq),.frame_timestamp(cts),.left_edge,.sample_ce,.cursor_x(ox),.cursor_y(oy),.cursor_z(oz),.normalized_pitch(opitch),.velocity_control(ovel),.depth_control(odepth),.state(ostate),.point_valid(opoint),.rebased(orebased),.stable_valid(ostable),.audio_cursor_x(ax),.audio_cursor_y(ay),.audio_cursor_z(az),.audio_pitch(apitch),.audio_velocity(avel),.audio_depth(adepth),.audio_valid(aval),.audio_sequence(aseq),.audio_timestamp(ats));
  localparam [1:0] S_DISENGAGED=0,S_ENGAGED=1,S_REBASED=2,S_DEGRADED=3;
  always #5 clk=~clk;
  integer fd,n,scan; integer iv,isat,igap,iedge,isample; integer est,erb,estab,eav; integer state_i; integer ex_seq; logic [31:0] source_timestamp,expected_frame_ts,expected_audio_ts,last_stable_ts; logic have_stable;
  logic signed [31:0] eoutx,eouty,eoutz,epitch,evel,edepth,eax,eay,eaz,eapitch,eavel,eadepth; logic [15:0] pseq,easeq; logic [31:0] pts,eats_file; logic [7:0] ereason;
  task automatic check_row;
    begin
      if (cseq!==pseq || ostate!==state_i[1:0] || opoint!==est || orebased!==erb || ostable!==estab || ox!==eoutx || oy!==eouty || oz!==eoutz || opitch!==epitch[15:0] || ovel!==evel[15:0] || odepth!==edepth[15:0]) $fatal(1,"cursor mismatch row=%0d seq=%h/%h state=%0d/%0d point=%b/%b rebased=%b/%b stable=%b/%b xyz=%0d,%0d,%0d/%0d,%0d,%0d pitch/vel/depth=%h,%h,%h/%h,%h,%h upstream cstrobe=%b cvalid=%b creason=%h vvalid=%b vreason=%h",n,cseq,pseq,ostate,state_i,opoint,est,orebased,erb,ostable,estab,ox,oy,oz,eoutx,eouty,eoutz,opitch,ovel,odepth,epitch,evel,edepth,cstrobe,cvalid,creason,vvalid,vreason);
      if (aval!==eav || (eav && (ax!==eax || ay!==eay || az!==eaz || apitch!==eapitch[15:0] || avel!==eavel[15:0] || adepth!==eadepth[15:0] || aseq!==easeq || ats!==expected_audio_ts))) $fatal(1,"audio mismatch row=%0d valid=%b/%b xyz=%0d,%0d,%0d/%0d,%0d,%0d seq/ts=%h/%h %h/%h",n,aval,eav,ax,ay,az,eax,eay,eaz,aseq,easeq,ats,expected_audio_ts);
    end
  endtask
  initial begin
    repeat(2) @(posedge clk); rst_n=1; @(negedge clk); profile_we=1; @(posedge clk); #1; @(negedge clk); profile_we=0; profile_commit=1; @(posedge clk); #1; profile_commit=0;
    fd=$fopen("../../tools/testdata/v2_input/cursor_replay_fast_01.vec","r"); if(!fd) $fatal(1,"cursor vector open failed"); n=0; have_stable=0; expected_audio_ts=0; last_stable_ts=0;
    while(!$feof(fd)) begin
      scan=$fscanf(fd,"%h %h %h %h %d %d %d %d %d %h %h %h %h %h %h %d %d %d %h %h %h %h %h %h %h %h %h %h %h %d\n",ex_seq,sensor_x,sensor_y,sensor_z,iv,isat,igap,iedge,isample,eoutx,eouty,eoutz,epitch,evel,edepth,state_i,erb,estab,pseq,pts,ereason,eax,eay,eaz,eapitch,eavel,eadepth,easeq,eats_file,eav);
      if(scan<30) begin $display("cursor fscanf count=%0d row=%0d",scan,n); break; end
      est = (state_i == 1) || (state_i == 2);
      // Each replay row includes the four-stage transport delay plus one
      // post-check idle edge; the latch free counter therefore advances by
      // seven ticks between report captures.
      expected_frame_ts=32'd2+(n*32'd7);
      if (isample && have_stable) expected_audio_ts=last_stable_ts;
      seq_in=ex_seq[15:0]; xyz_valid=iv; sat_in=isat; report_error=igap; left_edge=iedge; sample_ce=0;
      @(negedge clk); report_valid=1; @(posedge clk); #1; report_valid=0;
      // Latch, calibration/validity, and cursor are three registered stages.
      @(posedge clk); #1;
      @(posedge clk); #1;
      @(posedge clk); #1;
      @(posedge clk); #1;
      @(negedge clk); sample_ce=isample; @(posedge clk); #1; sample_ce=0;
      if (cts!==expected_frame_ts || lts!==expected_frame_ts) $fatal(1,"timestamp mismatch row=%0d latch=%h cal=%h exp=%h",n,lts,cts,expected_frame_ts);
      if (eav && !have_stable) $fatal(1,"audio marked valid before stable point row=%0d",n);
      check_row(); @(posedge clk); #1; if(cstrobe || cursor_strobe || validity_strobe || opoint || orebased) $fatal(1,"idle leakage row=%0d",n); if (state_i==1 && estab) begin have_stable=1; last_stable_ts=expected_frame_ts; end; n=n+1;
    end
    $fclose(fd); if(n<900) $fatal(1,"too few cursor rows %0d",n);
    // Dedicated adjacent A/B transport check: report_valid remains high over
    // two consecutive report edges, exercising every registered stage without
    // an idle gap between the latch samples.
    rst_n=0; repeat(2) @(posedge clk); rst_n=1;
    @(negedge clk); profile_we=1; @(posedge clk); #1; @(negedge clk); profile_we=0; profile_commit=1; @(posedge clk); #1; profile_commit=0;
    seq_in=16'd0; sensor_x=16'h0000; sensor_y=16'h8000; sensor_z=16'd1000; xyz_valid=1; sat_in=0; report_error=0; left_edge=1; report_valid=1;
    @(posedge clk); #1;
    seq_in=16'd1; sensor_x=16'h0AB0; sensor_y=16'h83E8; sensor_z=16'd1000; left_edge=0;
    @(posedge clk); #1; report_valid=0; left_edge=0;
    // The two calibrated bundles must emerge on consecutive cstrobe edges
    // with their own metadata before the delayed cursor validity stage.
    @(posedge clk); #1; if (!cstrobe || cseq!==16'd0) $fatal(1,"adjacent A bundle mismatch cstrobe=%b cseq=%h",cstrobe,cseq);
    @(posedge clk); #1; if (!cstrobe || cseq!==16'd1) $fatal(1,"adjacent B bundle mismatch cstrobe=%b cseq=%h",cstrobe,cseq);
    repeat(3) @(posedge clk); #1;
    if (cseq!==16'd1 || !opoint || ostate!==S_REBASED || ox!==32'sd32768 || oy!==32'sd32768) $fatal(1,"adjacent cursor B mismatch cseq=%h state=%0d point=%b xy=%0d,%0d",cseq,ostate,opoint,ox,oy);
    $display("tb_v2_cursor_replay PASS rows=%0d adjacent=A/B",n); $finish;
  end
endmodule
