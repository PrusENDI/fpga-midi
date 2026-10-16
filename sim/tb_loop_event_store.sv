`timescale 1ns/1ps
module tb_loop_event_store #(parameter USE_GOWIN_RAM=0);
  GSR GSR (.GSRI(1'b1));
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, abort=0, loop_boundary=0;
  reg ctrl_valid=0; wire ctrl_ready,ctrl_done;
  reg [2:0] ctrl_op=0; reg [1:0] ctrl_track=0;
  reg write_valid=0; wire write_ready;
  reg [1:0] write_track=0; reg [3:0] write_slot=0;
  reg [63:0] write_data=0;
  reg read_enable=0; reg [5:0] read_index=0;
  wire read_valid,read_slot_valid; wire [63:0] read_data;
  wire active_bank,shadow_bank,commit_pending,commit_ack,busy,active_valid;
  wire [19:0] record_count; wire [3:0] overflow;
  loop_event_store #(.USE_GOWIN_RAM(USE_GOWIN_RAM)) dut(.*);
  task step; begin @(posedge clk); #1; end endtask
  task command(input [2:0] op,input [1:0] tr);
    begin @(negedge clk); ctrl_valid=1;ctrl_op=op;ctrl_track=tr;
      if (!ctrl_ready) #1;
      if (!ctrl_ready) $fatal(1,"command unexpectedly blocked op=%d",op);
      step(); @(negedge clk);ctrl_valid=0;
    end
  endtask
  task append(input [1:0] tr,input [3:0] slot,input [63:0] data);
    begin @(negedge clk);write_valid=1;write_track=tr;write_slot=slot;write_data=data;#1;
      if (!write_ready) $fatal(1,"append blocked %d %d",tr,slot);
      step(); @(negedge clk);write_valid=0;
    end
  endtask
  task readcheck(input [5:0] idx,input valid_slot,input [63:0] data);
    begin @(negedge clk);read_enable=1;read_index=idx;step();
      if (!read_valid || read_slot_valid!==valid_slot || read_data!==data)
        $fatal(1,"read idx=%d valid=%b slot=%b data=%h expected=%h",idx,read_valid,read_slot_valid,read_data,data);
      @(negedge clk);read_enable=0;step(); if(read_valid) $fatal(1,"read valid not cleared");
    end
  endtask
  task boundary;
    begin @(negedge clk);loop_boundary=1;step();@(negedge clk);loop_boundary=0;end
  endtask
  task waitcopy;
    integer n; begin n=0;while(busy && n<200) begin step();n=n+1;end
      if(busy || !ctrl_done) $fatal(1,"copy did not complete");end
  endtask
  integer t,s,wait_cycles,accept_snapshot;
  integer command_accepts=0;
  always @(posedge clk)
    if(rst_n && ctrl_valid && ctrl_ready) command_accepts=command_accepts+1;
  reg old_bank;
  initial begin
    step();step();@(negedge clk);rst_n=1;step();
    if(active_valid || record_count || overflow || busy || active_bank===shadow_bank) $fatal(1,"reset metadata");
    readcheck(0,0,0);
    for(t=0;t<4;t=t+1) for(s=0;s<16;s=s+1) append(t,s,64'h1000+t*16+s);
    if(record_count!=={4{5'd16}}) $fatal(1,"track counts");
    readcheck(0,0,0);
    @(negedge clk);write_valid=1;write_track=2;write_slot=0;write_data=64'hdead;#1;
    if(write_ready) $fatal(1,"full accepted");step();
    if(overflow!==4'b0100) $fatal(1,"overflow not sticky");
    @(negedge clk);write_valid=0;loop_boundary=1;
    command(3,0); if(!commit_pending || commit_ack || active_valid) $fatal(1,"commit too early");
    loop_boundary=0;step();old_bank=active_bank;
    @(negedge clk);write_valid=1;write_track=1;write_slot=0;#1;
    if(write_ready) $fatal(1,"pending commit permits write");
    repeat(3) step();if(overflow!==4'b0100) $fatal(1,"pending backpressure counted as overflow");
    @(negedge clk);write_valid=0;
    boundary();if(!commit_ack || active_bank===old_bank || !active_valid) $fatal(1,"commit failed");
    for(t=0;t<64;t=t+1) readcheck(t,1,64'h1000+t);
    command(0,0);
    // Playback continues while port A copies every active slot.
    for(t=0;t<32;t=t+1) readcheck(t,1,64'h1000+t);
    waitcopy(); if(record_count!=={4{5'd16}}) $fatal(1,"copy counts");
    command(1,1);if(record_count[9:5]!==0) $fatal(1,"clear track");
    append(1,0,64'h5555);readcheck(16,1,64'h1010);
    command(3,0);boundary();readcheck(16,1,64'h5555);readcheck(17,0,0);
    for(t=0;t<16;t=t+1) readcheck(t,1,64'h1000+t);
    for(t=32;t<64;t=t+1) readcheck(t,1,64'h1000+t);
    command(5,2);waitcopy();if(record_count[14:10]!==0 || record_count[9:5]!==1) $fatal(1,"record prepare");
    append(2,0,64'h6666);command(3,0);boundary();
    // RECORD must replace only the selected track, including its validity map.
    for(t=0;t<64;t=t+1) begin
      if(t<16 || t>=48) readcheck(t,1,64'h1000+t);
      else if(t==16) readcheck(t,1,64'h5555);
      else if(t==32) readcheck(t,1,64'h6666);
      else readcheck(t,0,0);
    end
    // Hold a clear command across the whole copy. It must not be accepted
    // early, lost when copy finishes, or replayed after valid is deasserted.
    command(0,0);accept_snapshot=command_accepts;
    @(negedge clk);ctrl_valid=1;ctrl_op=1;ctrl_track=3;#1;
    if(ctrl_ready) $fatal(1,"copy failed to backpressure control");
    wait_cycles=0;
    while(!ctrl_ready && wait_cycles<150) begin
      step();wait_cycles=wait_cycles+1;
      if(command_accepts!==accept_snapshot) $fatal(1,"control accepted while copy busy");
    end
    if(!ctrl_ready || record_count[19:15]!==16) $fatal(1,"held clear lost copy completion");
    step();if(!ctrl_done || record_count[19:15]!==0 || command_accepts!==accept_snapshot+1)
      $fatal(1,"held clear not accepted exactly once");
    @(negedge clk);ctrl_valid=0;
    append(3,0,64'haaaa);repeat(3) step();
    if(record_count[19:15]!==1 || ctrl_done || command_accepts!==accept_snapshot+1)
      $fatal(1,"held clear replayed after handshake");
    command(4,0);if(record_count || busy || overflow) $fatal(1,"command abort");
    // Command ABORT bypasses busy during copy, as well as a pending commit.
    old_bank=active_bank;command(0,0);repeat(9) step();command(4,0);
    if(!ctrl_done || busy || record_count || active_bank!==old_bank) $fatal(1,"command abort mid-copy");
    repeat(130) step();if(busy || record_count || ctrl_done) $fatal(1,"aborted copy resumed");
    readcheck(32,1,64'h6666);readcheck(48,1,64'h1030);
    append(0,0,64'hdead);command(3,0);
    @(negedge clk);ctrl_valid=1;ctrl_op=4;loop_boundary=1;#1;
    if(!ctrl_ready) $fatal(1,"command abort blocked by pending commit");step();
    if(!ctrl_done || commit_ack || active_bank!==old_bank || busy || record_count)
      $fatal(1,"command abort lost to boundary");
    @(negedge clk);ctrl_valid=0;loop_boundary=0;
    readcheck(32,1,64'h6666);readcheck(48,1,64'h1030);
    command(0,0);repeat(9) step();@(negedge clk);abort=1;step();
    if(busy || record_count || commit_pending) $fatal(1,"abort mid-copy");
    @(negedge clk);abort=0;readcheck(16,1,64'h5555);
    append(0,0,64'h7777);command(3,0);old_bank=active_bank;
    @(negedge clk);abort=1;loop_boundary=1;step();
    if(commit_ack || active_bank!==old_bank || commit_pending || record_count) $fatal(1,"abort priority");
    @(negedge clk);abort=0;loop_boundary=0;
    readcheck(16,1,64'h5555);
    command(0,0);waitcopy();command(2,0);if(record_count || overflow) $fatal(1,"clear all");
    command(3,0);if(!commit_pending || active_bank!==old_bank) $fatal(1,"empty commit must wait");
    boundary();if(!commit_ack || commit_pending || active_bank===old_bank || active_valid) $fatal(1,"empty clear commit");
    readcheck(16,0,0);
    append(0,0,64'h8888);
    // A replacement of an existing valid slot is never accepted.
    @(negedge clk);write_valid=1;write_slot=0;#1;if(write_ready) $fatal(1,"overwrite accepted");step();
    if(overflow) $fatal(1,"non-full backpressure is not overflow");
    @(negedge clk);write_valid=0;
    // Control wins arbitration; a held write is accepted once control leaves.
    @(negedge clk);ctrl_valid=1;ctrl_op=1;ctrl_track=3;
    write_valid=1;write_track=0;write_slot=1;write_data=64'h9999;#1;
    if(write_ready || !ctrl_ready) $fatal(1,"control/write arbitration");step();
    if(record_count[4:0]!==1) $fatal(1,"unaccepted write changed count");
    @(negedge clk);ctrl_valid=0;#1;if(!write_ready) $fatal(1,"held write not released");step();
    if(record_count[4:0]!==2) $fatal(1,"held write not accepted");
    @(negedge clk);write_valid=0;
    command(3,0);
    @(negedge clk);read_enable=1;read_index=0;step();
    if(!read_valid || read_slot_valid || read_data!==0) $fatal(1,"continuous old-bank read");
    @(negedge clk);loop_boundary=1;step();
    if(read_valid || !commit_ack) $fatal(1,"swap stale read");
    @(negedge clk);loop_boundary=0;step();
    if(!read_valid || !read_slot_valid || read_data!==64'h8888) $fatal(1,"continuous read failed after swap");
    @(negedge clk);read_index=1;step();
    if(!read_valid || !read_slot_valid || read_data!==64'h9999) $fatal(1,"continuous read second new slot");
    @(negedge clk);read_index=2;step();
    if(!read_valid || read_slot_valid || read_data!==0) $fatal(1,"continuous invalid slot completion");
    @(negedge clk);read_enable=0;step();if(read_valid) $fatal(1,"continuous read did not stop");
    @(negedge clk);rst_n=0;step();@(negedge clk);rst_n=1;readcheck(0,0,0);
    $display("tb_loop_event_store PASS");$finish;
  end
  initial begin #100000; $fatal(1,"timeout");end
endmodule
