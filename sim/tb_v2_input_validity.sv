`timescale 1ns/1ps
module tb_v2_input_validity;
  import v2_input_pkg::*;
  logic clk=0, rst_n=0, frame_in_valid=0, valid_xyz=1, saturated=0, gap=0, touch=0, presence=1;
  logic signed [15:0] raw_x,raw_y,raw_z; logic [15:0] sequence_id; logic [31:0] timestamp_ticks; logic [7:0] cal_epoch=7;
  logic profile_shadow_we=0, profile_commit=0; logic signed [31:0] snx=100,sny=-200,snz=300,scx=0,scy=0,sgx=65536,sgy=65536,sgz=65536;
  logic signed [31:0] wxmin=-1000,wxmax=1000,wymin=-1000,wymax=1000,wzmin=-1000,wzmax=1000; logic [7:0] shepoch=7;
  logic signed [31:0] x,y,z; logic [15:0] os; logic [31:0] ot; logic ov,osat,og,otouch,opres; logic [7:0] oe,reason,active_epoch;
  logic active_profile_valid; logic fv,lost,degraded,note; logic [15:0] gaps; logic [7:0] vreason;
  always #5 clk=~clk;
  v2_input_calibration cal(.clk,.rst_n,.frame_in_valid,.raw_x,.raw_y,.raw_z,.sequence_id,.timestamp_ticks,.valid_xyz,.saturated,.gap,.calibration_epoch_in(cal_epoch),.touch,.presence,.profile_shadow_we,.profile_commit,.shadow_neutral_x(snx),.shadow_neutral_y(sny),.shadow_neutral_z(snz),.shadow_coupling_x(scx),.shadow_coupling_y(scy),.shadow_gain_x(sgx),.shadow_gain_y(sgy),.shadow_gain_z(sgz),.shadow_ws_x_min(wxmin),.shadow_ws_x_max(wxmax),.shadow_ws_y_min(wymin),.shadow_ws_y_max(wymax),.shadow_ws_z_min(wzmin),.shadow_ws_z_max(wzmax),.shadow_epoch(shepoch),.calibrated_x(x),.calibrated_y(y),.calibrated_z(z),.output_sequence(os),.output_timestamp_ticks(ot),.output_touch(otouch),.output_presence(opres),.output_valid(ov),.output_saturated(osat),.output_gap(og),.output_calibration_epoch(oe),.calibration_reason(reason),.active_epoch,.active_profile_valid);
  v2_position_validity val(.clk,.rst_n,.frame_in_valid,.valid_xyz,.saturated,.gap,.sequence_id,.calibration_epoch(cal_epoch),.active_epoch,.active_profile_valid,.calibration_reason_in(reason),.frame_valid(fv),.lost,.degraded,.gap_count(gaps),.calibration_reason(vreason),.note_permitted(note));
  task send(input signed [15:0] ax,ay,az,input logic av,asat,ag,input [15:0] seq,input [7:0] ep);
    begin @(negedge clk); raw_x=ax;raw_y=ay;raw_z=az;valid_xyz=av;saturated=asat;gap=ag;sequence_id=seq;cal_epoch=ep;frame_in_valid=1; @(posedge clk); #1; @(negedge clk); frame_in_valid=0; end
  endtask
  initial begin
    raw_x=0;raw_y=0;raw_z=0;sequence_id=0;timestamp_ticks=0;
    repeat(2) @(posedge clk); rst_n=1;
    @(negedge clk); profile_shadow_we=1; @(negedge clk); profile_shadow_we=0; profile_commit=1; @(negedge clk); profile_commit=0;
    send(-32768,32767,-1,1,0,0,1,7);
    if (x !== -1000 || y !== 1000 || z !== -301 || !ov || !fv || !note || reason !== V2_REASON_CLAMP) $fatal(1,"valid transform/ clamp x=%0d y=%0d z=%0d ov=%b fv=%b note=%b reason=%h",x,y,z,ov,fv,note,reason);
    send(0,0,0,0,0,0,2,7);
    if (x !== 0 || y !== 0 || z !== 0 || ov || note || !(reason & V2_REASON_INVALID)) $fatal(1,"invalid gate");
    send(0,0,0,1,0,0,3,7);
    if (!ov || !note || reason !== 0) $fatal(1,"stale reason recovery reason=%h",reason);
    send(0,0,0,1,1,0,4,7);
    if (x !== 0 || ov || note || !(reason & V2_REASON_SATURATED)) $fatal(1,"saturation gate reason=%h",reason);
    // Isolate modulo-wrap check from the prior sequence history.
    rst_n=0; repeat(2) @(posedge clk); rst_n=1;
    @(negedge clk); profile_shadow_we=1; @(negedge clk); profile_shadow_we=0; profile_commit=1; @(negedge clk); profile_commit=0;
    send(0,0,0,1,0,0,16'hffff,7); send(0,0,0,1,0,0,16'h0000,7);
    if (lost || gaps != 0) $fatal(1,"sequence wrap lost=%b gaps=%0d",lost,gaps);
    send(0,0,0,1,0,0,16'h0003,7);
    if (!lost || gaps != 2) $fatal(1,"gap count lost=%b gaps=%0d",lost,gaps);
    send(0,0,0,1,0,0,16'h0004,8);
    if (ov || note || !(reason & V2_REASON_EPOCH) || !(reason & V2_REASON_PROFILE)) $fatal(1,"epoch mismatch reason=%h",reason);
    send(0,0,0,1,0,0,16'h0005,7);
    if (!ov || !note) $fatal(1,"epoch recovery ov=%b note=%b reason=%h active=%0d ep=%0d profile=%b",ov,note,reason,active_epoch,cal_epoch,active_profile_valid);
    @(negedge clk); snx=500; profile_shadow_we=1; @(negedge clk); profile_shadow_we=0;
    send(500,0,0,1,0,0,6,7);
    if (x !== 400) $fatal(1,"shadow changed active before commit x=%0d",x);
    @(negedge clk); profile_commit=1; @(negedge clk); profile_commit=0;
    send(500,0,0,1,0,0,7,7);
    if (x !== 0) $fatal(1,"committed profile neutral x=%0d",x);
    $display("tb_v2_input_validity PASS"); $finish;
  end
endmodule
