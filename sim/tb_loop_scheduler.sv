`timescale 1ns/1ps
module tb_loop_scheduler;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0,run=0,stop=0,flush=0,reset_position=0,boundary_ready=1;
  reg [15:0] bpm_value=60;
  wire read_enable; wire [5:0] read_index;
  reg read_valid=0,read_slot_valid=0; reg [63:0] read_data=0;
  reg event_ready=1,respond=1;
  wire event_valid,sixteenth_ce,loop_boundary,stall,fault_valid,heartbeat_toggle;
  wire [63:0] event_data; wire [6:0] loop_tick;
  wire [7:0] fault_code; wire [31:0] fault_info; wire [15:0] active_bpm;
  loop_scheduler #(.CLK_HZ(10000)) dut(.*);
  reg [63:0] slots[0:63]; reg [63:0] occupied=0;
  reg [63:0] received[0:2047]; integer received_count=0;
  integer cycles=0,ce_count=0,boundaries=0,last_ce=0,first_ce=0;
  integer previous_ce=0,interval=0;
  always @(posedge clk) begin
    cycles=cycles+1;
    read_valid<=read_enable && respond;
    read_slot_valid<=read_enable && occupied[read_index];
    read_data<=slots[read_index];
    if(rst_n && event_valid && event_ready) begin
      received[received_count]=event_data; received_count=received_count+1;
    end
    #1;
    if(rst_n && sixteenth_ce) begin
      if(ce_count==0) first_ce=cycles;
      previous_ce=last_ce; last_ce=cycles; ce_count=ce_count+1;
    end
    if(rst_n && loop_boundary) boundaries=boundaries+1;
  end
  function [63:0] ev(input [2:0] kind,input [6:0] tick,input [6:0] duration,input [6:0] note);
    ev=0; ev[2:0]=kind;ev[11:5]=tick;ev[18:12]=duration;ev[25:19]=note;ev[4:3]=2;
  endfunction
  task step(input integer n); repeat(n) @(negedge clk); endtask
  task check(input bit ok,input string why); if(!ok) $fatal(1,"%s",why); endtask
  task reset;
    begin
      rst_n=0; run=0;stop=0;flush=0;reset_position=0;event_ready=1;respond=1;bpm_value=60;occupied=0;
      step(3); rst_n=1; received_count=0;ce_count=0;boundaries=0;step(2);
    end
  endtask
  task wait_events(input integer n);
    integer timeout;
    begin timeout=0; while(received_count<n && timeout<4000) begin step(1);timeout=timeout+1;end
      check(received_count>=n,"event delivery timeout"); end
  endtask
  task wait_ce(input integer n);
    integer timeout;
    begin timeout=0; while(ce_count<n && timeout<400000) begin step(1);timeout=timeout+1;end
      check(ce_count>=n,"musical deadline timeout"); end
  endtask
  integer i,n,start_cycle; reg [63:0] held;
  initial begin
    for(i=0;i<64;i=i+1) slots[i]=0;
    reset;
    // Reversed slot ordering must not defeat global event class priority.
    slots[0]=ev(2,0,0,10);slots[1]=ev(0,0,1,60);slots[63]=ev(1,0,0,61);
    occupied[0]=1;occupied[1]=1;occupied[63]=1;run=1;start_cycle=cycles;
    wait_events(3);
    check(first_ce-start_cycle<=1,"PLAY must schedule tick zero immediately");
    check(received[0]===slots[63] && received[1]===slots[1] && received[2]===slots[0],"global OFF ON CONTROL priority including slot63");
    check(loop_tick==0,"scan completion must retain current tick");
    wait_events(4); check(received[3]===ev(1,1,0,60),"duration generates exact end note-off");
    check(last_ce-first_ce==2500 || last_ce-first_ce==2501,"60 BPM tick interval");
    check(!fault_valid,"normal schedule fault");

    reset;bpm_value=180;occupied=64'hffffffffffffffff;
    for(i=0;i<64;i=i+1) slots[i]=ev(0,0,1,i);
    run=1;wait_events(128);step(500);
    check(received_count==128 && !fault_valid,"all64 slots scanned without losses at180 BPM");
    for(i=0;i<64;i=i+1) begin
      check(received[i]===ev(0,0,1,i),"all-slot note-on order");
      check(received[64+i]===ev(1,1,0,i),"all-slot derived note-off order");
    end

    reset;
    for(i=0;i<5;i=i+1) begin slots[i]=ev(i+3,0,0,60);occupied[i]=1;end
    slots[63]=ev(0,0,0,99); // stale word in an invalid slot must be ignored
    run=1;step(600);
    check(received_count==0 && !fault_valid,"RAM boundary/alloff/error/reserved types and invalid slots are ignored");

    reset; occupied[63]=1;slots[63]=ev(0,0,0,64);event_ready=0;run=1;
    step(400);check(event_valid,"stalled matching event must be offered");held=event_data;n=read_index;
    step(100);check(event_valid && event_data===held && read_index==n && stall,"backpressure stability");
    event_ready=1;wait_events(1);step(500);check(received_count==1,"resume loses or duplicates event");
    reset;occupied[0]=1;slots[0]=ev(0,0,0,65);event_ready=0;run=1;
    step(200);check(event_valid,"stop setup stalled note-on"); stop=1;event_ready=1;#1;
    check(!event_valid,"stop must suppress stale handshake combinationally");step(1);stop=0;
    wait_events(1);check(received[0][2:0]==4,"stop sends all notes off");step(3000);
    check(received_count==1 && loop_tick==0 && ce_count==1,"held run cannot restart after STOP");
    run=0;step(3);n=received_count;run=1;wait_events(n+1);
    check(received[n][2:0]==0,"new PLAY edge restarts after STOP");
    flush=1;step(1);flush=0;wait_events(n+2);
    check(received[n+1][2:0]==4 && loop_tick==0,"flush releases voices and clears position");
    run=0;step(3);n=received_count;run=1;wait_events(n+1);reset_position=1;step(1);reset_position=0;wait_events(n+2);
    check(received[n+1][2:0]==4 && loop_tick==0,"reset_position releases voices");

    // A later PLAY can arrive while the previous cleanup is backpressured.
    // Its edge must survive until cleanup drains, including the drain edge.
    for(i=0;i<2;i=i+1) begin
      reset;occupied[0]=1;slots[0]=ev(0,0,0,67);run=1;event_ready=0;step(200);
      run=0;#1;check(!event_valid,"falling run cancels stalled note-on immediately");
      step(2);check(event_valid && event_data==4,"falling run releases voices");
      run=1;
      if(i==0) begin step(20);check(event_valid && event_data==4,"cleanup remains held during pending PLAY");end
      event_ready=1;wait_events(2);
      check(received[0]==4 && received[1]===slots[0] && ce_count==2,
            "fresh PLAY during RELEASE survives until cleanup accepted");
    end
    for(i=0;i<4;i=i+1) begin
      reset;run=1;event_ready=0;step(20);run=0;step(2);run=1;step(2);
      case(i)
        0: stop=1;
        1: flush=1;
        2: reset_position=1;
        3: run=0;
      endcase
      step(1);stop=0;flush=0;reset_position=0;event_ready=1;wait_events(1);step(600);
      check(received_count==1 && ce_count==1 && loop_tick==0,
            "cancellation discards pending PLAY without automatic restart");
    end

    reset; run=1;wait_ce(2);bpm_value=180;wait_ce(128);
    check(loop_tick==127 && active_bpm==60 && boundaries==0,"BPM changes only at real boundary");
    check(last_ce-first_ce>=317500 && last_ce-first_ce<=317501,"127 complete 60 BPM intervals");
    step(1000);check(loop_tick==127 && boundaries==0,"tick127 retains full musical duration");
    wait_ce(129);wait_events(2);step(5);
    check(last_ce-first_ce>=320000 && last_ce-first_ce<=320001,"loop has128 complete intervals");
    check(received[0][2:0]==4 && received[1][2:0]==3 && boundaries==1,"boundary all-off before boundary event");
    check(active_bpm==180 && loop_tick==0,"boundary applies pending BPM");
    wait_ce(130);interval=last_ce-previous_ce;check(interval==833 || interval==834,"180 BPM tick interval");
    check(!fault_valid,"boundary schedule fault");

    reset;slots[0]=ev(0,127,2,70);slots[1]=ev(0,127,1,71);occupied[1:0]=3;run=1;wait_ce(130);step(600);
    check(received_count==4,"duration end128 and129 must not generate ghost note-off");
    check(received[0][2:0]==0 && received[1][2:0]==0 && received[2][2:0]==4 && received[3][2:0]==3,"clipped duration boundary order");

    reset;bpm_value=180;run=1;event_ready=0;wait_ce(129);
    check(event_valid && event_data==4 && boundaries==0,"boundary starts with held all-off");
    step(20);check(event_valid && event_data==4 && boundaries==0 && !read_enable,"boundary all-off stable without premature reads or commit");
    boundary_ready=0;event_ready=1;step(1);event_ready=0;
    step(20);check(!event_valid && boundaries==0 && !read_enable,"boundary waits for commit permission");
    boundary_ready=1;step(1);
    check(event_valid && event_data==3 && received_count==1,"boundary marker follows accepted all-off");
    step(20);check(event_valid && event_data==3 && boundaries==0 && !read_enable,"boundary marker stable without premature reads or commit");
    event_ready=1;step(2);check(boundaries==1 && received_count==2,"accepted marker commits exactly once");

    reset;bpm_value=180;run=1;event_ready=0;wait_ce(129);event_ready=1;step(1);event_ready=0;step(1);
    check(event_valid && event_data==3,"setup stalled boundary marker");step(850);
    check(fault_valid && fault_code==2 && boundaries==0 && received_count==1,"overdue marker must fault without committing");
    check(event_valid && event_data==4,"fault cleanup replaces stalled marker");
    step(100);check(event_valid && event_data==4 && stall && boundaries==0,"fault cleanup remains stable under backpressure");
    event_ready=1;wait_events(2);check(received[1]==4,"fault cleanup accepted without boundary leakage");

    reset;occupied[0]=1;slots[0]=ev(0,0,0,66);event_ready=0;run=1;step(2600);
    check(fault_valid && fault_code==2 && loop_tick==0,"blocked output deadline overrun faults and stops");
    event_ready=1;wait_events(1);check(received[0][2:0]==4,"overrun cancels note-on and releases voices");
    reset;respond=0;run=1;step(50);check(fault_valid && fault_code==3,"missing RAM response timeout");
    wait_events(1);check(received[0][2:0]==4,"read timeout releases voices");
    reset;bpm_value=59;run=1;step(10);check(fault_valid && fault_code==1,"invalid starting BPM faults");
    check(received_count==1 && received[0][2:0]==4,"invalid BPM releases voices");
    run=0;step(3);n=received_count;bpm_value=60;run=1;wait_ce(1);step(500);
    check(fault_valid && fault_code==1 && !stall,"fault diagnostic sticky across fresh PLAY");
    bpm_value=181;wait_ce(129);step(10);
    check(received_count==n+1 && received[n][2:0]==4 && boundaries==0 && loop_tick==0,
          "invalid BPM at boundary halts without committing store");
    $display("tb_loop_scheduler PASS");$finish;
  end
endmodule
