// Minimal independent V2 scheduler: scans one selected track and emits held
// 96-bit events at explicit loop ticks, with boundary/stop cancellation.
module v2_loop_scheduler(input logic clk,rst_n,run,stop,flush,input logic [6:0] loop_tick,
 input logic read_valid,read_slot_valid,input logic [95:0] read_data,
 output logic read_enable,output logic [3:0] read_index,output logic event_valid,input logic event_ready,
 output logic [95:0] event_data,output logic fault_valid);
 logic [3:0] index; assign read_index=index; assign read_enable=run&&!stop&&!flush&&!event_valid;
 always_ff @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin index<=0;event_valid<=0;event_data<=0;fault_valid<=0;end
  else if(stop||flush) begin event_valid<=0;index<=0;end
  else begin
   if(event_valid&&event_ready) begin event_valid<=0;index<=index+1'b1;end
   if(run&&read_valid&&read_slot_valid&&!event_valid) begin event_data<=read_data;event_valid<=1;end
  end
 end
endmodule
