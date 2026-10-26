`timescale 1ns/1ps
module tb_v2_input_replay;
  import v2_input_pkg::*;
  logic clk=0, rst_n=0, frame_in_valid=0;
  logic signed [16:0] raw_x,raw_y; logic [16:0] raw_z; logic [15:0] sequence_id; logic [31:0] timestamp_ticks;
  logic valid_xyz,saturated,gap; logic [7:0] cal_epoch; logic touch=0,presence=1;
  logic profile_shadow_we=0,profile_commit=0; logic signed [31:0] snx=0,sny=0,snz=0,scx=0,scy=0,sgx=65536,sgy=65536,sgz=65536;
  logic signed [31:0] wxmin=-32768,wxmax=32767,wymin=-32768,wymax=32767,wzmin=0,wzmax=65535; logic [7:0] shepoch=0;
  logic signed [31:0] x,y,z; logic [15:0] os; logic [31:0] ot; logic ov,osat,og,otouch,opres; logic [7:0] oe,reason,active_epoch; logic active_profile_valid;
  logic fv,lost,degraded,note; logic [15:0] gaps; logic [7:0] vreason;
  always #5 clk=~clk;
  v2_input_calibration cal(.clk,.rst_n,.frame_in_valid,.raw_x,.raw_y,.raw_z,.sequence_id,.timestamp_ticks,.valid_xyz,.saturated,.gap,.calibration_epoch_in(cal_epoch),.touch,.presence,.profile_shadow_we,.profile_commit,.shadow_neutral_x(snx),.shadow_neutral_y(sny),.shadow_neutral_z(snz),.shadow_coupling_x(scx),.shadow_coupling_y(scy),.shadow_gain_x(sgx),.shadow_gain_y(sgy),.shadow_gain_z(sgz),.shadow_ws_x_min(wxmin),.shadow_ws_x_max(wxmax),.shadow_ws_y_min(wymin),.shadow_ws_y_max(wymax),.shadow_ws_z_min(wzmin),.shadow_ws_z_max(wzmax),.shadow_epoch(shepoch),.calibrated_x(x),.calibrated_y(y),.calibrated_z(z),.output_sequence(os),.output_timestamp_ticks(ot),.output_touch(otouch),.output_presence(opres),.output_valid(ov),.output_saturated(osat),.output_gap(og),.output_calibration_epoch(oe),.calibration_reason(reason),.active_epoch,.active_profile_valid);
  v2_position_validity val(.clk,.rst_n,.frame_in_valid,.valid_xyz,.saturated,.gap,.sequence_id,.calibration_epoch(cal_epoch),.active_epoch,.active_profile_valid,.calibration_reason_in(reason),.frame_valid(fv),.lost,.degraded,.gap_count(gaps),.calibration_reason(vreason),.note_permitted(note));
  integer fd,rc,i; logic signed [31:0] ex,ey,ez; logic [31:0] ets; logic [15:0] eos,egaps; logic [7:0] ereason; logic ef,el,ed,en;
  initial begin
    rst_n=0; #2; rst_n=1; repeat(2) @(posedge clk);
    @(negedge clk); profile_shadow_we=1; @(posedge clk); #1; @(negedge clk); profile_shadow_we=0; profile_commit=1; @(posedge clk); #1; profile_commit=0;
    fd=$fopen("../../tools/testdata/v2_input/replay_fast_01.vec","r"); if(!fd) $fatal(1,"vector open failed"); i=0;
    while(!$feof(fd)) begin
      rc=$fscanf(fd,"%h %h %h %h %h %d %d %d %d %h %h %h %h %d %d %d %h %h %d\n",eos,ets,raw_x,raw_y,raw_z,rc,valid_xyz,saturated,gap,cal_epoch,ex,ey,ez,ef,el,ed,egaps,ereason,en);
      if(rc<19) break;
      @(negedge clk); frame_in_valid=0; sequence_id=eos; timestamp_ticks=ets; frame_in_valid=1;
      @(posedge clk); #1;
      if ((os!==eos)||(ot!==ets)||(fv!==ef)||(lost!==el)||(degraded!==ed)||(gaps!==egaps)||(vreason!==ereason)||(note!==en))
        $fatal(1,"meta frame=%0d seq=%h/%h ts=%h/%h fv=%b/%b lost=%b/%b deg=%b/%b gaps=%h/%h reason=%h/%h note=%b/%b",i,os,eos,ot,ets,fv,ef,lost,el,degraded,ed,gaps,egaps,vreason,ereason,note,en);
      if (fv && ((x!==ex)||(y!==ey)||(z!==ez))) $fatal(1,"xyz frame=%0d got=%h %h %h exp=%h %h %h",i,x,y,z,ex,ey,ez);
      i=i+1; frame_in_valid=0;
    end
    $fclose(fd); if(i<900) $fatal(1,"too few replay frames %0d",i);
    $display("tb_v2_input_replay PASS frames=%0d",i); $finish;
  end
endmodule
