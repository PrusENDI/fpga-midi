`timescale 1ns/1ps
module tb_v2_input_validity;
  logic clk=0, rst_n=0, frame_in_valid=0, valid_xyz=1, saturated=0, gap=0, touch=0, presence=1;
  logic signed [15:0] raw_x,raw_y,raw_z; logic [15:0] sequence_id; logic [31:0] timestamp_ticks; logic [7:0] cal_epoch=7;
  logic profile_shadow_we=0, profile_commit=0; logic signed [31:0] snx=100,sny=-200,snz=300,scx=0,scy=0,sgx=65536,sgy=65536,sgz=65536;
  logic signed [31:0] wxmin=-1000,wxmax=1000,wymin=-1000,wymax=1000,wzmin=-1000,wzmax=1000; logic [7:0] shepoch=7;
  logic signed [31:0] x,y,z; logic [15:0] os; logic [31:0] ot; logic ov,osat,og,otouch,opres; logic [7:0] oe,reason;
  logic fv,lost,degraded,note; logic [15:0] gaps; logic [7:0] vreason;
  always #5 clk=~clk;
  v2_input_calibration cal(.clk,.rst_n,.frame_in_valid,.raw_x,.raw_y,.raw_z,.sequence_id,.timestamp_ticks,.valid_xyz,.saturated,.gap,.calibration_epoch_in(cal_epoch),.touch,.presence,.profile_shadow_we,.profile_commit,.shadow_neutral_x(snx),.shadow_neutral_y(sny),.shadow_neutral_z(snz),.shadow_coupling_x(scx),.shadow_coupling_y(scy),.shadow_gain_x(sgx),.shadow_gain_y(sgy),.shadow_gain_z(sgz),.shadow_ws_x_min(wxmin),.shadow_ws_x_max(wxmax),.shadow_ws_y_min(wymin),.shadow_ws_y_max(wymax),.shadow_ws_z_min(wzmin),.shadow_ws_z_max(wzmax),.shadow_epoch(shepoch),.calibrated_x(x),.calibrated_y(y),.calibrated_z(z),.output_sequence(os),.output_timestamp_ticks(ot),.output_touch(otouch),.output_presence(opres),.output_valid(ov),.output_saturated(osat),.output_gap(og),.output_calibration_epoch(oe),.calibration_reason(reason),.active_profile_valid());
  v2_position_validity val(.clk,.rst_n,.frame_in_valid,.valid_xyz,.saturated,.gap,.sequence_id,.calibration_epoch(cal_epoch),.active_epoch(shepoch),.calibration_reason_in(reason),.frame_valid(fv),.lost,.degraded,.gap_count(gaps),.calibration_reason(vreason),.note_permitted(note));
  task send(input signed [15:0] ax,ay,az,input logic av,asat,ag,input [15:0] seq);
    begin @(negedge clk); raw_x=ax;raw_y=ay;raw_z=az;valid_xyz=av;saturated=asat;gap=ag;sequence_id=seq;frame_in_valid=1; @(posedge clk); #1; @(negedge clk); frame_in_valid=0; end
  endtask
  initial begin
    raw_x=0;raw_y=0;raw_z=0;sequence_id=0;timestamp_ticks=0;
    repeat(2) @(posedge clk); rst_n=1;
    @(negedge clk); profile_shadow_we=1; @(negedge clk); profile_shadow_we=0; profile_commit=1; @(negedge clk); profile_commit=0;
    send(-32768,32767,-1,1,0,0,1);
    if (x !== -1000 || y !== 1000 || z !== -301 || !ov) $fatal(1,"transform x=%0d y=%0d z=%0d valid=%b reason=%h oe=%0d",x,y,z,ov,reason,oe);
    send(0,0,0,1,1,0,2); if (ov || note) $fatal(1,"saturated accepted");
    send(0,0,0,1,0,1,5); if (ov || !lost || gaps != 2) $fatal(1,"gap handling ov=%b lost=%b gaps=%0d",ov,lost,gaps);
    $display("tb_v2_input_validity PASS"); $finish;
  end
endmodule





