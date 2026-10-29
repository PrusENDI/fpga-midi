`timescale 1ns/1ps
// Differential replay of the actual timed RTL, against an immutable git base.
// The script renames the baseline modules; neither DUT is the scalar reference.
module tb_v2_cursor_timed_compare;
  initial begin #30000000; $fatal(1,"timed replay watchdog timeout"); end
  logic clk=0, rst_n=0, frame_in_valid=0, sample_ce=0;
  always #5 clk=~clk;
  integer sample_accumulator=0, audio_checks=0, reference_differences=0, sample_window_differences=0;
  // Independent 48 kHz fractional enable in the same 100 MHz clock domain.
  always @(negedge clk) begin
    if(!rst_n) begin sample_accumulator=0; sample_ce=0; end
    else begin
      sample_accumulator=sample_accumulator+48000;
      sample_ce=(sample_accumulator>=100000000);
      if(sample_ce) sample_accumulator=sample_accumulator-100000000;
    end
  end
  logic signed [31:0] frame_x=0,frame_y=0,frame_z=0;
  logic frame_valid=0,frame_saturated=0,frame_gap=0,frame_degraded=0,left_edge=0;
  logic [7:0] calibration_reason=0;
  logic [15:0] frame_sequence=0;
  logic [31:0] frame_timestamp=0;
  wire signed [31:0] x[0:1],y[0:1],z[0:1],ax[0:1],ay[0:1],az[0:1];
  wire [15:0] pitch[0:1],vel[0:1],depth[0:1],ap[0:1],av[0:1],ad[0:1],aseq[0:1];
  wire [31:0] ats[0:1];
  wire [1:0] state[0:1];
  wire point[0:1],rebase[0:1],stable[0:1],avalid[0:1],done[0:1];
`define PORTS(I) .clk,.rst_n,.frame_in_valid,.frame_x,.frame_y,.frame_z,.frame_valid,.frame_saturated,.frame_gap,.frame_degraded,.calibration_reason,.frame_sequence,.frame_timestamp,.left_edge,.sample_ce,.cursor_x(x[I]),.cursor_y(y[I]),.cursor_z(z[I]),.normalized_pitch(pitch[I]),.velocity_control(vel[I]),.depth_control(depth[I]),.state(state[I]),.point_valid(point[I]),.rebased(rebase[I]),.stable_valid(stable[I]),.audio_cursor_x(ax[I]),.audio_cursor_y(ay[I]),.audio_cursor_z(az[I]),.audio_pitch(ap[I]),.audio_velocity(av[I]),.audio_depth(ad[I]),.audio_valid(avalid[I]),.audio_sequence(aseq[I]),.audio_timestamp(ats[I]),.frame_output_valid(done[I])
  v2_cursor_filter_timed_baseline base(`PORTS(0));
  v2_cursor_filter_timed candidate(`PORTS(1));
`undef PORTS
  // Snapshot every completed frame independently of the different latencies.
  logic [196:0] results[0:1][0:1023];
  integer counts[0:1];
  integer cycles=0, launched=0, start_cycle[0:1023], max_latency[0:1];
  integer latency[0:1][0:1023], replay_max[0:1];
  integer same_latency_checks=0, expect_same_latency;
  logic [15:0] accepted_sequence[0:1023];
  logic [31:0] accepted_timestamp[0:1023];
  wire [15:0] completed_sequence[0:1];
  wire [31:0] completed_timestamp[0:1];
  assign completed_sequence[0]=base.in_sequence;
  assign completed_sequence[1]=candidate.in_sequence;
  assign completed_timestamp[0]=base.in_timestamp;
  assign completed_timestamp[1]=candidate.in_timestamp;
  integer i, monitor_dut;
  logic [191:0] expected_stable[0:1], expected_audio[0:1];
  logic model_stable_valid[0:1], model_audio_valid[0:1];
  always @(posedge clk) begin
    #1;
    cycles=cycles+1;
    if (rst_n) begin
      for(monitor_dut=0;monitor_dut<2;monitor_dut=monitor_dut+1) begin
        // Model snapshots from the preceding completed stable frame; NBA
        // ordering means a simultaneous publication is consumed next sample.
        if(sample_ce && model_stable_valid[monitor_dut]) begin
          expected_audio[monitor_dut]=expected_stable[monitor_dut];
          model_audio_valid[monitor_dut]=1;
          audio_checks=audio_checks+1;
        end
        if(avalid[monitor_dut]!==model_audio_valid[monitor_dut] ||
          {ax[monitor_dut],ay[monitor_dut],az[monitor_dut],ap[monitor_dut],av[monitor_dut],ad[monitor_dut],aseq[monitor_dut],ats[monitor_dut]} !== expected_audio[monitor_dut])
          $fatal(1,"independent audio snapshot mismatch dut=%0d cycle=%0d",monitor_dut,cycles);
        model_stable_valid[monitor_dut]=stable[monitor_dut];
        if(done[monitor_dut]) begin
        if(counts[monitor_dut]>=launched) $fatal(1,"unexpected completion dut=%0d count=%0d",monitor_dut,counts[monitor_dut]);
        if(completed_sequence[monitor_dut]!==accepted_sequence[counts[monitor_dut]] ||
           completed_timestamp[monitor_dut]!==accepted_timestamp[counts[monitor_dut]])
          $fatal(1,"frame FIFO sequence/timestamp mismatch dut=%0d row=%0d",monitor_dut,counts[monitor_dut]);
        results[monitor_dut][counts[monitor_dut]]={completed_sequence[monitor_dut],completed_timestamp[monitor_dut],x[monitor_dut],y[monitor_dut],z[monitor_dut],pitch[monitor_dut],vel[monitor_dut],depth[monitor_dut],state[monitor_dut],point[monitor_dut],rebase[monitor_dut],stable[monitor_dut]};
        if(point[monitor_dut] && stable[monitor_dut] && state[monitor_dut]==1)
          expected_stable[monitor_dut]={x[monitor_dut],y[monitor_dut],z[monitor_dut],pitch[monitor_dut],vel[monitor_dut],depth[monitor_dut],completed_sequence[monitor_dut],completed_timestamp[monitor_dut]};
        if(cycles-start_cycle[counts[monitor_dut]]>max_latency[monitor_dut]) max_latency[monitor_dut]=cycles-start_cycle[counts[monitor_dut]];
        latency[monitor_dut][counts[monitor_dut]]=cycles-start_cycle[counts[monitor_dut]];
        counts[monitor_dut]=counts[monitor_dut]+1;
        end
      end
      if(sample_ce && {ax[0],ay[0],az[0],ap[0],av[0],ad[0],aseq[0],ats[0]} !==
                      {ax[1],ay[1],az[1],ap[1],av[1],ad[1],aseq[1],ats[1]})
        sample_window_differences=sample_window_differences+1;
    end
  end
  task automatic compare_frame(input integer row, input bit check_audio);
    integer timeout;
    begin
      timeout=0;
      while(counts[0]<=row || counts[1]<=row) begin
        @(negedge clk); timeout=timeout+1;
        if(timeout>2083) $fatal(1,"frame missed one audio sample interval row=%0d counts=%0d/%0d",row,counts[0],counts[1]);
      end
      if(results[0][row]!==results[1][row]) $fatal(1,"frame mismatch row=%0d baseline=%h candidate=%h",row,results[0][row],results[1][row]);
      if(expect_same_latency) begin
        if(latency[0][row]!==latency[1][row])
          $fatal(1,"frame latency mismatch row=%0d baseline=%0d candidate=%0d",row,latency[0][row],latency[1][row]);
        same_latency_checks=same_latency_checks+1;
      end
      // Normal replay waits for the next independent audio enable. Burst
      // replay scores every completion while the FIFO continues draining.
      if(check_audio) begin
      @(negedge clk);
      while(!sample_ce) @(negedge clk);
      @(negedge clk);
      if({ax[0],ay[0],az[0],ap[0],av[0],ad[0],avalid[0],aseq[0],ats[0]} !==
         {ax[1],ay[1],az[1],ap[1],av[1],ad[1],avalid[1],aseq[1],ats[1]})
        $fatal(1,"audio bundle/sequence/timestamp mismatch row=%0d",row);
      // Every stable publication has the metadata of the accepted input.
      if(results[0][row][0] && results[0][row][2] && results[0][row][4:3]==1 &&
         (aseq[0]!==accepted_sequence[row] || ats[0]!==accepted_timestamp[row]))
        $fatal(1,"publication metadata mismatch row=%0d",row);
      end
    end
  endtask
  integer fd,n,scan,iv,isat,igap,iedge,isample,expect_sample_window;
  logic [15:0] sensor_x,sensor_y,sensor_z;
  logic [31:0] unused_words[0:20];
  string vector_path;
  initial begin
    counts[0]=0; counts[1]=0; max_latency[0]=0; max_latency[1]=0;
    expected_stable[0]=0; expected_stable[1]=0; expected_audio[0]=0; expected_audio[1]=0;
    model_stable_valid[0]=0; model_stable_valid[1]=0; model_audio_valid[0]=0; model_audio_valid[1]=0;
    repeat(3) @(negedge clk); rst_n=1;
    if(!$value$plusargs("EXPECT_SAMPLE_WINDOW=%d",expect_sample_window)) $fatal(1,"missing EXPECT_SAMPLE_WINDOW");
    if(!$value$plusargs("EXPECT_SAME_LATENCY=%d",expect_same_latency)) $fatal(1,"missing EXPECT_SAME_LATENCY");
    if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing VECTORS");
    fd=$fopen(vector_path,"r"); if(!fd) $fatal(1,"cannot open vectors %s",vector_path);
    n=0;
    while(!$feof(fd)) begin
      scan=$fscanf(fd,"%h %h %h %h %d %d %d %d %d %h %h %h %h %h %h %d %d %d %h %h %h %h %h %h %h %h %h %h %h %d\n",
        frame_sequence,sensor_x,sensor_y,sensor_z,iv,isat,igap,iedge,isample,
        unused_words[0],unused_words[1],unused_words[2],unused_words[3],unused_words[4],unused_words[5],
        unused_words[6],unused_words[7],unused_words[8],unused_words[9],unused_words[10],unused_words[11],
        unused_words[12],unused_words[13],unused_words[14],unused_words[15],unused_words[16],unused_words[17],
        unused_words[18],unused_words[19],unused_words[20]);
      if(scan!=30) $fatal(1,"malformed vector row=%0d fields=%0d",n,scan);
      // The replay uses the default identity calibration: centered signed XY,
      // unsigned Z. Invalid/gap/saturation flags remain part of each bundle.
      frame_x=$signed({1'b0,sensor_x})-32'sd32768;
      frame_y=$signed({1'b0,sensor_y})-32'sd32768;
      frame_z={16'd0,sensor_z}; frame_valid=iv; frame_saturated=isat;
      frame_gap=igap; frame_degraded=0; left_edge=iedge;
      frame_timestamp=n*500000; // 200 Hz timestamps at 100 MHz.
      start_cycle[launched]=cycles;
      accepted_sequence[launched]=frame_sequence; accepted_timestamp[launched]=frame_timestamp;
      launched=launched+1;
      frame_in_valid=1; @(negedge clk); frame_in_valid=0;
      compare_frame(n,1);
      // These vectors' golden outputs come from the scalar reference. Report
      // pre-existing timed/reference differences without relaxing DUT equality.
      if(results[0][n][148:0] !== {unused_words[0],unused_words[1],unused_words[2],unused_words[3][15:0],unused_words[4][15:0],unused_words[5][15:0],unused_words[6][1:0],((unused_words[6]==1)||(unused_words[6]==2)),unused_words[7][0],unused_words[8][0]}) begin
        reference_differences=reference_differences+1;
        if(reference_differences<=3) $display("BASELINE_SCALAR_DIFFERENCE row=%0d timed=%h scalar_xyz=%h,%h,%h",n,results[0][n][148:0],unused_words[0],unused_words[1],unused_words[2]);
      end
      n=n+1;
      @(negedge clk);
    end
    $fclose(fd);
    if(n!=976) $fatal(1,"wrong replay row count %0d",n);
    replay_max[0]=max_latency[0]; replay_max[1]=max_latency[1];
    // Four adjacent accepted bundles exercise the retained FIFO with distinct
    // values and metadata. Both timed DUTs must emit all four in order.
    for(i=0;i<4;i=i+1) begin
      frame_sequence=976+i; frame_timestamp=(976+i)*500000;
      frame_x=-30000+i*1000; frame_y=5000+i*3000; frame_z=12000+i*500;
      frame_valid=1; frame_saturated=0; frame_gap=0; left_edge=1;
      start_cycle[launched]=cycles;
      accepted_sequence[launched]=frame_sequence; accepted_timestamp[launched]=frame_timestamp;
      launched=launched+1;
      frame_in_valid=1; @(negedge clk);
    end
    frame_in_valid=0;
    for(n=976;n<980;n=n+1) compare_frame(n,0);
    // Train two identical non-burst frames, then position another publication
    // across an independent sample edge. The per-DUT oracle must accept only
    // the causally correct old/new snapshot, never mixed values or metadata.
    for(n=980;n<983;n=n+1) begin
      if(n==982) begin
        while(((100000000-sample_accumulator+47999)/48000) > latency[0][981]+7) @(negedge clk);
      end
      frame_sequence=n; frame_timestamp=n*500000;
      frame_x=0; frame_y=0; frame_z=12000;
      start_cycle[launched]=cycles;
      accepted_sequence[launched]=frame_sequence; accepted_timestamp[launched]=frame_timestamp;
      launched=launched+1;
      frame_in_valid=1; @(negedge clk); frame_in_valid=0;
      compare_frame(n,0);
      if(n<982) begin repeat(2) @(negedge clk); end
    end
    // Allow the candidate's updated stable snapshot to reach the next sample.
    repeat(2085) @(negedge clk);
    repeat(4) @(negedge clk);
    if(counts[0]!=983 || counts[1]!=983) $fatal(1,"lost or extra frames %0d/%0d",counts[0],counts[1]);
    // Even the burst drains well inside the 500,000 cycle 200 Hz budget.
    if(max_latency[0]>=500000 || max_latency[1]>=500000) $fatal(1,"200 Hz throughput exceeded");
    if(audio_checks<100) $fatal(1,"insufficient independent audio coverage %0d",audio_checks);
    if(expect_sample_window && sample_window_differences==0) $fatal(1,"publication/sample boundary case not exercised");
    if(!expect_sample_window && sample_window_differences!=0) $fatal(1,"baseline self-check audio differs");
    if(expect_same_latency && same_latency_checks!=983) $fatal(1,"incomplete latency coverage %0d",same_latency_checks);
    $display("tb_v2_cursor_timed_compare PASS rows=976 adjacent=4 frames=%0d/%0d replay_max_cycles=%0d/%0d burst_max_cycles=%0d/%0d audio_checks=%0d baseline_scalar_differences=%0d sample_window_differences=%0d same_latency_checks=%0d",counts[0],counts[1],replay_max[0],replay_max[1],max_latency[0],max_latency[1],audio_checks,reference_differences,sample_window_differences,same_latency_checks);
    $finish;
  end
endmodule
