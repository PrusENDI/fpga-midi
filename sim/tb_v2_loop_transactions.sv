`timescale 1ns/1ps
module tb_v2_loop_transactions;
  logic clk=0,rst_n=0,abort=0,boundary=0,cv=0,wrv=0;
  logic [2:0] cop=0,ct=0,wt=0,rt=0;
  logic [4:0] ws=0,ri=0;
  logic [95:0] wd=0,dnote=0;
  logic wrdy,crdy,done,rv,rsv;
  logic [95:0] rdata;
  logic ab,sb,cp,ack,busy,av;
  logic [35:0] counts;
  logic [5:0] ov;
  logic [95:0] sched_data;
  logic sv,sr=0,se,sl;
  logic [2:0] str;
  logic [4:0] si;
  logic [6:0] tick=0;
  always #5 clk=~clk;

  v2_loop_event_store store(
    .clk,.rst_n,.abort,.loop_boundary(boundary),.ctrl_valid(cv),.ctrl_ready(crdy),
    .ctrl_op(cop),.ctrl_track(ct),.ctrl_done(done),.write_valid(wrv),.write_ready(wrdy),
    .write_track(wt),.write_slot(ws),.write_data(wd),.read_enable(se),.read_track(str),
    .read_index(si),.read_valid(rv),.read_slot_valid(rsv),.read_data(rdata),
    .active_bank(ab),.shadow_bank(sb),.commit_pending(cp),.commit_ack(ack),.busy,
    .record_count(counts),.overflow(ov),.active_valid(av));

  logic run_s=0,flush_s=0;
  v2_loop_scheduler sched(
    .clk,.rst_n,.run(run_s),.stop(1'b0),.flush(flush_s),.selected_track(3'd0),
    .loop_tick(tick),.read_valid(rv),.read_slot_valid(rsv),.read_data(rdata),
    .read_enable(se),.read_track(str),.read_index(si),.event_valid(sv),
    .event_ready(sr),.event_data(sched_data),.fault_valid(sl),.loop_boundary());

  integer i,wait_cycles;
  logic first_bank;

  task automatic command(input logic [2:0] op,input logic [2:0] track);
    begin
      @(negedge clk); cop=op; ct=track; cv=1;
      @(posedge clk); #1; cv=0;
      if (op==3'd5 || op==3'd0) begin
        wait_cycles=0;
        while (!done && wait_cycles<500) begin @(posedge clk); #1; wait_cycles=wait_cycles+1; end
        if (!done) $fatal(1,"store copy did not complete for op %0d",op);
      end
    end
  endtask

  task automatic put(input logic [2:0] track,input logic [4:0] slot,input logic [95:0] data);
    begin
      @(negedge clk); wt=track; ws=slot; wd=data; wrv=1;
      #1; if(!wrdy) $fatal(1,"write blocked at track=%0d slot=%0d",track,slot);
      @(posedge clk); #1; wrv=0;
    end
  endtask

  initial begin
    repeat(2) @(posedge clk); rst_n=1;

    // A full 32-slot track must be appendable and must report overflow on the
    // next write while the active bank remains untouched.
    command(3'd5,3'd0);
    for (i=0;i<32;i=i+1) begin
      dnote=96'd0; dnote[90:88]=3'd0; dnote[15:0]=i[15:0];
      if (i==31) dnote[94:91]=4'd1; // only slot 31 is scheduler-visible
      put(3'd0,i[4:0],dnote);
    end
    @(negedge clk); wt=0; ws=5'd31; wd=96'h1; wrv=1;
    #1; if(wrdy) $fatal(1,"full 32-slot track accepted a 33rd append");
    @(posedge clk); #1; wrv=0;
    if (!ov[0]) $fatal(1,"full track did not latch overflow");

    command(3'd3,3'd0);
    @(negedge clk); boundary=1; @(posedge clk); #1; boundary=0;
    if(!ack || !av) $fatal(1,"commit did not publish active bank");
    first_bank=ab;

    // Scheduler must scan slot 31 and keep its event stable under backpressure.
    run_s=1; wait_cycles=0;
    while(!sv && wait_cycles<1200) begin @(posedge clk); #1; wait_cycles=wait_cycles+1; end
    if(!sv || sched_data[94:91]!==4'd1 || sched_data[15:0]!==16'd31)
      $fatal(1,"scheduler did not reach slot31: valid=%b data=%h cycles=%0d",sv,sched_data,wait_cycles);
    dnote=sched_data; repeat(3) begin @(posedge clk); #1; if(!sv || sched_data!==dnote) $fatal(1,"scheduler event changed while stalled"); end
    sr=1; @(posedge clk); #1; sr=0; if(sv) $fatal(1,"scheduler did not handshake slot31 event");
    run_s=0;

    // Prepare a new shadow recording, then abort it; the published active bank
    // must remain valid and selected throughout the copy/abort sequence.
    command(3'd5,3'd1);
    if (ab!==first_bank || !av) $fatal(1,"prepare record damaged active bank");
    put(3'd1,5'd0,96'h200000000000000000000002);
    abort=1; @(posedge clk); #1; abort=0;
    if (ab!==first_bank || !av) $fatal(1,"abort damaged active bank");

    $display("tb_v2_loop_transactions PASS slots=32 overflow=%b",ov[0]);
    $finish;
  end
  initial begin #500000; $fatal(1,"v2 loop transaction timeout"); end
endmodule
