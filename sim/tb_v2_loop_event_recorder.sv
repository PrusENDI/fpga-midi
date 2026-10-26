`timescale 1ns/1ps
module tb_v2_loop_event_recorder;
  logic clk=0,rst_n=0,record_start=0,record_stop=0,abort=0,event_valid=0,event_ready;
  logic [95:0] event_data=0; logic [31:0] event_tick=0; logic write_ready=1;
  logic loop_write_valid; logic [95:0] loop_write_data;
  logic read_req=0; logic [2:0] read_track=0; logic [15:0] read_index=0;
  logic read_valid; logic [95:0] read_data; logic [15:0] event_count; logic [15:0] track_event_count [0:5];
  logic [7:0] fault_code; logic left_edge_armed,gate_state,recording;
  always #5 clk=~clk;
  v2_loop_event_recorder #(.DEPTH(2)) dut(.*);
  task automatic push(input [2:0] tr,input [31:0] tt,input [3:0] typ);
    begin @(negedge clk); event_data=0; event_data[94:91]=typ; event_data[90:88]=tr; event_data[23:16]=8'h02; event_tick=tt; event_valid=1;
      @(posedge clk); #1; if(!event_ready) $fatal(1,"event rejected"); @(negedge clk); event_valid=0; end
  endtask
  initial begin
    repeat(2) @(posedge clk); rst_n=1; @(negedge clk); record_start=1; @(posedge clk); #1; @(negedge clk); record_start=0;
    push(0,1,1); push(5,2,4); if(event_count!==2) $fatal(1,"count=%0d",event_count);
    // Read back the independent track store.
    @(negedge clk); read_track=5; read_index=0; read_req=1; @(posedge clk); #1; read_req=0;
    if(!read_valid || read_data[90:88]!==5) $fatal(1,"track store");
    @(negedge clk); record_stop=1; @(posedge clk); #1; @(negedge clk); record_stop=0;
    // A stopped recorder must not accept a write.
    @(negedge clk); event_data=0; event_data[90:88]=1; event_tick=9; event_valid=1;
    @(posedge clk); #1; if(event_ready) $fatal(1,"stopped recorder accepted event"); @(negedge clk); event_valid=0;
    if(event_count!==2) $fatal(1,"stopped recorder accepted event");
    $display("tb_v2_loop_event_recorder PASS"); $finish;
  end
endmodule
