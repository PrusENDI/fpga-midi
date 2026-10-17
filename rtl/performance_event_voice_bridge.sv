// Convert ordered control-plane events into the legacy one-cycle mixer inputs.
// ready is held high for the current voice mixer, so no event is accepted until
// a clock edge and event/data remain stable under a future backpressure change.
module performance_event_voice_bridge(
 input wire clk,rst_n,input wire event_valid,output wire event_ready,input wire [63:0] event_data,
 output reg note_on,note_off,expression_valid,output reg soft_timbre,
 output reg [6:0] note_number,output reg [7:0] velocity);
 import performance_event_pkg::*;
 assign event_ready=rst_n;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin note_on<=0;note_off<=0;expression_valid<=0;soft_timbre<=0;note_number<=0;velocity<=0;end
  else begin
   note_on<=0;note_off<=0;expression_valid<=0;
    if(event_valid && event_ready) begin
    soft_timbre<=event_data[EVENT_FLAG_SOFT_TIMBRE];
    note_number<=event_data[25:19]; velocity<=event_data[33:26];
    case(event_data[2:0])
     EVENT_NOTE_ON: note_on<=1;
     EVENT_NOTE_OFF,EVENT_ALL_NOTES_OFF: note_off<=1;
     EVENT_CONTROL_POINT: expression_valid<=1;
     default:;
    endcase
   end
  end
 end
endmodule
