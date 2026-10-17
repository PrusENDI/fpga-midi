// Task-6 integration boundary: byte-level control plane plus the existing
// four-voice mixer. Physical UART RX and MGC3130 adapters remain top-level
// board wiring; this wrapper is also suitable for deterministic simulation.
module loop_audio_path #(
 parameter integer CLK_HZ=50_000_000,
 parameter integer USE_GOWIN_RAM=0,
 parameter integer OP_TIMEOUT_CYCLES=CLK_HZ,
 parameter integer BOUNDARY_TIMEOUT_CYCLES=1_700_000_000,
 parameter integer RX_TIMEOUT_CYCLES=500000
)(
 input wire clk,rst_n,
 input wire rx_valid,output wire rx_ready,input wire [7:0] rx_data,
 output wire tx_valid,input wire tx_ready,output wire [7:0] tx_data,
 input wire record_start,
 input wire live_valid,output wire live_ready,input wire [63:0] live_data,
 input wire record_valid,output wire record_ready,input wire [63:0] record_data,
 input wire modulation_valid,output wire modulation_ready,input wire [63:0] modulation_data,
 input wire adapter_idle,
 output wire signed [15:0] mixed_sample,output wire sample_valid,
 output wire [2:0] active_voice_count,output wire [3:0] mode,
 output wire [1:0] selected_track,output wire [15:0] start_enter,start_exit,
 output wire [6:0] loop_tick,output wire active_valid,output wire fault_latched,
 output wire flush_events,
 input wire [15:0] report_count,xyz_count,
  input wire adapter_overflow);
 wire out_valid,out_ready;wire [63:0] out_data;
 wire [15:0] bpm_shadow,active_bpm;
 wire live_enable,record_enable,play_enable;wire [1:0] track;
 wire [7:0] diag_flags;
 wire [2:0] router_debug;
  wire [7:0] router_status;
 assign diag_flags={flush_events,live_enable,live_ready,live_valid,
                    adapter_overflow,router_debug};
 reg [7:0] note_on_count;
 reg [15:0] sample_count;
 loop_control_plane #(.CLK_HZ(CLK_HZ),.USE_GOWIN_RAM(USE_GOWIN_RAM),
   .OP_TIMEOUT_CYCLES(OP_TIMEOUT_CYCLES),.BOUNDARY_TIMEOUT_CYCLES(BOUNDARY_TIMEOUT_CYCLES),.RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)) control(
   .clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
   .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.record_start(record_start),
   .in_valid(live_valid),.in_ready(live_ready),.in_data(live_data),
   .record_in_valid(record_valid),.record_in_ready(record_ready),.record_in_data(record_data),.adapter_idle(adapter_idle),
   .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.mode(mode),.selected_track(track),
   .bpm_shadow(bpm_shadow),.active_bpm(active_bpm),.start_enter(start_enter),.start_exit(start_exit),
   .loop_tick(loop_tick),.active_valid(active_valid),.fault_latched(fault_latched),
   .live_enable(live_enable),.record_enable(record_enable),.play_enable(play_enable),
   .flush_events(flush_events),.router_debug(router_debug),.router_status(router_status),
   .report_count(report_count),.xyz_count(xyz_count),.sample_count(sample_count),
   .note_on_count(note_on_count),.active_voice_count(active_voice_count),.diag_flags(diag_flags));
 assign selected_track=track;
 // Control-plane playback has priority over external modulation. The adapter
 // holds modulation_valid while modulation_ready is low, so no event is lost.
 wire bridge_valid,bridge_ready;wire [63:0] bridge_data;
 assign bridge_valid=out_valid || modulation_valid;
 assign bridge_data=out_valid ? out_data : modulation_data;
 // The control-plane event has priority at the bridge.  It must still see
 // ready when a modulation point is pending; otherwise the bridge consumes
 // the control event repeatedly while the router waits forever for ready.
 assign out_ready=bridge_ready;
 assign modulation_ready=bridge_ready && !out_valid;
 wire note_on,note_off,expression_valid;wire [6:0] note_number;wire [7:0] velocity;
 performance_event_voice_bridge bridge(.clk(clk),.rst_n(rst_n),.event_valid(bridge_valid),.event_ready(bridge_ready),.event_data(bridge_data),
   .note_on(note_on),.note_off(note_off),.expression_valid(expression_valid),.note_number(note_number),.velocity(velocity));
 mgc3130_voice_mixer #(.CLK_HZ(CLK_HZ)) mixer(.clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),
   .note_number(note_number),.velocity(velocity),.expression_valid(expression_valid),.sample_valid(sample_valid),
   .mixed_sample(mixed_sample),.active_voice_count(active_voice_count));
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin note_on_count<=0; sample_count<=0; end
   else begin
     if(note_on && note_on_count!=8'hff) note_on_count<=note_on_count+1'b1;
     if(sample_valid && sample_count!=16'hffff) sample_count<=sample_count+1'b1;
   end
 end
endmodule
