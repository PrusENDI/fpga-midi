// Merge immediate live events with completed recording events. Completed
// events carry flags[61]=1 and are stored but never monitored as live audio.
module input_event_mux(
 input wire clk,rst_n,flush,
 input wire live_valid, output wire live_ready, input wire [63:0] live_data,
 input wire record_valid, output wire record_ready, input wire [63:0] record_data,
 output wire out_valid, input wire out_ready, output wire [63:0] out_data,
 output wire pending_debug);
 reg pending; reg [63:0] data;
 assign live_ready=!flush && !pending && !record_valid && out_ready;
 assign record_ready=!flush && !pending && out_ready;
 assign out_valid=!flush && (pending || record_valid || live_valid);
 assign out_data=pending ? data : record_valid ? (record_data | (64'd1<<61)) : live_data;
 assign pending_debug=pending;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin pending<=0;data<=0;end
  else if(flush) begin pending<=0;data<=0;end
  else begin
   if(pending && out_ready) pending<=0;
   if(!pending && out_valid && !out_ready) begin pending<=1;data<=out_data;end
  end
 end
endmodule
