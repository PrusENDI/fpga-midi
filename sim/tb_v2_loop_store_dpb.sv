`timescale 1ns/1ps
module tb_v2_loop_store_dpb;
  GSR GSR(.GSRI(1'b1));
  logic clk=0,rst_n=0,abort=0,boundary=0,cv=0,wrv=0;
  logic [2:0] cop=0,ct=0,wt=0,rt=0; logic [4:0] ws=0,ri=0;
  logic [95:0] wd=0; logic wrdy,crdy,done,rv,rsv; logic [95:0] rdata;
  logic ab,sb,cp,ack,busy,av; logic [35:0] counts; logic [5:0] ov;
  logic run_s=0,flush_s=0,sv,sr=1,se,sl; logic [95:0] sched_data; logic [2:0] str; logic [4:0] si; logic [6:0] tick=0;
  always #5 clk=~clk;
  v2_loop_event_store_dpb store(.clk,.rst_n,.abort,.loop_boundary(boundary),.ctrl_valid(cv),.ctrl_ready(crdy),.ctrl_op(cop),.ctrl_track(ct),.ctrl_done(done),.write_valid(wrv),.write_ready(wrdy),.write_track(wt),.write_slot(ws),.write_data(wd),.read_enable(se),.read_track(str),.read_index(si),.read_valid(rv),.read_slot_valid(rsv),.read_data(rdata),.active_bank(ab),.shadow_bank(sb),.commit_pending(cp),.commit_ack(ack),.busy,.record_count(counts),.overflow(ov),.active_valid(av));
  v2_loop_scheduler sched(.clk,.rst_n,.run(run_s),.stop(1'b0),.flush(flush_s),.selected_track(3'd0),.loop_tick(tick),.read_valid(rv),.read_slot_valid(rsv),.read_data(rdata),.read_enable(se),.read_track(str),.read_index(si),.event_valid(sv),.event_ready(sr),.event_data(sched_data),.fault_valid(sl),.loop_boundary());
  integer i,wait_cycles; logic first_bank; logic [95:0] d;
  task automatic command(input logic [2:0] op);
    begin @(negedge clk); cop=op; ct=0; cv=1; @(posedge clk); #1; cv=0; wait_cycles=0;
      if(op==3'd5) begin while(!done && wait_cycles<500) begin @(posedge clk); #1; wait_cycles=wait_cycles+1; end if(!done)$fatal(1,"DPB copy timeout"); end
    end
  endtask
  task automatic put(input logic [4:0] slot,input logic [95:0] data);
    begin @(negedge clk); wt=0; ws=slot; wd=data; wrv=1; #1; if(!wrdy)$fatal(1,"DPB write blocked slot=%0d",slot); @(posedge clk); #1; wrv=0; end
  endtask
  initial begin
    repeat(2)@(posedge clk); rst_n=1; command(3'd5);
    for(i=0;i<32;i=i+1) begin d=96'd0; if(i==31)d[94:91]=4'd1; d[90:88]=0; d[87:80]=0; d[15:0]=i[15:0]; put(i[4:0],d); end
    command(3'd3); @(negedge clk); boundary=1; @(posedge clk); #1; boundary=0; if(!ack||!av)$fatal(1,"DPB commit"); first_bank=ab;
    run_s=1; wait_cycles=0; while(!sv&&wait_cycles<1500)begin @(posedge clk);#1;wait_cycles=wait_cycles+1;end
    if(!sv||sched_data[94:91]!==4'd1||sched_data[15:0]!==16'd31)$fatal(1,"DPB scheduler slot31 valid=%b data=%h",sv,sched_data);
    run_s=0; command(3'd5); if(ab!==first_bank||!av)$fatal(1,"DPB prepare damaged active"); abort=1; @(posedge clk);#1;abort=0; if(ab!==first_bank||!av)$fatal(1,"DPB abort damaged active");
    $display("tb_v2_loop_store_dpb PASS slots=32 dpb=6"); $finish;
  end
  initial begin #500000;$fatal(1,"DPB loop timeout");end
endmodule
