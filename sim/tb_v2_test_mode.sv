`timescale 1ns/1ps
module tb_v2_test_mode;
  logic clk=0, rst_n=0, sample_ce=0;
  logic csr_valid=0, csr_write=0; logic [7:0] csr_addr=8'hA0; logic [31:0] csr_wdata=0;
  wire csr_ready, csr_rvalid; wire [31:0] csr_rdata; wire signed [15:0] mixed_sample;
  wire sample_valid; wire [31:0] active_bitmap, sample_counter; wire test_active, fault;
  string out_dir; integer fd, i, count, nonzero; integer timeout;
  always #5 clk=~clk;
  v2_test_mode dut(.*);

  task automatic write_count(input integer value);
    begin
      @(negedge clk); csr_wdata=((value & 24'hFFFFFF) << 8) | 8'd1; csr_valid=1; csr_write=1;
      @(posedge clk); #1; csr_valid=0; csr_write=0;
      if (!test_active && value != 0) $fatal(1,"count %0d did not enable",value);
      if (value == 0 && test_active) $fatal(1,"disable did not clear active");
    end
  endtask

  task automatic read_config;
    begin
      @(negedge clk); csr_wdata=0; csr_valid=1; csr_write=0;
      @(posedge clk); #1;
      if (!csr_rvalid || csr_rdata[7:0] !== 8'd1) $fatal(1,"readback invalid rvalid=%b data=%h",csr_rvalid,csr_rdata);
      csr_valid=0;
    end
  endtask

  task automatic sample_once;
    begin
      @(negedge clk); sample_ce=1;
      @(posedge clk); #1; sample_ce=0;
      if (!sample_valid && test_active) $fatal(1,"missing sample_valid");
    end
  endtask

  initial begin
    if (!$value$plusargs("OUT_DIR=%s",out_dir)) out_dir=".";
    repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
    write_count(1);
    if (active_bitmap !== 32'h00000001 || sample_counter !== 0) $fatal(1,"N=1 state bitmap=%h counter=%0d",active_bitmap,sample_counter);
    read_config();
    for (count=1; count<=32; count=count*2) begin
      write_count(count);
      if (active_bitmap !== ((count==32) ? 32'hFFFFFFFF : ((32'hFFFFFFFF >> (32-count)))))
        $fatal(1,"bitmap mismatch N=%0d bitmap=%h",count,active_bitmap);
      fd=$fopen($sformatf("%s/tone_%0d.csv",out_dir,count),"w"); if(fd==0) $fatal(1,"open samples N=%0d",count);
      nonzero=0;
      for(i=0;i<4096;i=i+1) begin
        sample_once();
        if (mixed_sample != 0) nonzero=nonzero+1;
        $fwrite(fd,"%0d\n",$signed(mixed_sample));
      end
      $fclose(fd);
      if (nonzero < 100) $fatal(1,"N=%0d insufficient nonzero samples=%0d",count,nonzero);
      if (sample_counter !== 32'd4096) $fatal(1,"N=%0d sample counter=%0d",count,sample_counter);
    end
    @(negedge clk); csr_wdata={24'd33,8'd1}; csr_valid=1; csr_write=1;
    @(posedge clk); #1; csr_valid=0; csr_write=0;
    if (!fault || active_bitmap !== 32'hFFFFFFFF) $fatal(1,"invalid count not faulted fault=%b bitmap=%h",fault,active_bitmap);
    write_count(0);
    sample_once();
    if (sample_valid || mixed_sample !== 0 || active_bitmap !== 0) $fatal(1,"disable state invalid");
    $display("tb_v2_test_mode PASS files=%0d",6);
    $finish;
  end
  initial begin #5_000_000; $fatal(1,"test mode timeout"); end
endmodule
