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
 input wire adapter_idle,
 output wire signed [15:0] mixed_sample,output wire sample_valid,
 output wire [2:0] active_voice_count,output wire [3:0] mode,
 output wire [6:0] loop_tick,output wire active_valid,output wire fault_latched);
 wire out_valid,out_ready;wire [63:0] out_data;
 wire selected_track;wire [15:0] bpm_shadow,active_bpm,start_enter,start_exit;
 wire live_enable,record_enable,play_enable;wire [1:0] track;
 loop_control_plane #(.CLK_HZ(CLK_HZ),.USE_GOWIN_RAM(USE_GOWIN_RAM),
   .OP_TIMEOUT_CYCLES(OP_TIMEOUT_CYCLES),.BOUNDARY_TIMEOUT_CYCLES(BOUNDARY_TIMEOUT_CYCLES),.RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)) control(
   .clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
   .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.record_start(record_start),
   .in_valid(live_valid),.in_ready(live_ready),.in_data(live_data),
   .record_in_valid(record_valid),.record_in_ready(record_ready),.record_in_data(record_data),.adapter_idle(adapter_idle),
   .out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),.mode(mode),.selected_track(track),
   .bpm_shadow(bpm_shadow),.active_bpm(active_bpm),.start_enter(start_enter),.start_exit(start_exit),
   .loop_tick(loop_tick),.active_valid(active_valid),.fault_latched(fault_latched),
   .live_enable(live_enable),.record_enable(record_enable),.play_enable(play_enable));
 wire note_on,note_off,expression_valid;wire [6:0] note_number;wire [7:0] velocity;
 performance_event_voice_bridge bridge(.clk(clk),.rst_n(rst_n),.event_valid(out_valid),.event_ready(out_ready),.event_data(out_data),
   .note_on(note_on),.note_off(note_off),.expression_valid(expression_valid),.note_number(note_number),.velocity(velocity));
 mgc3130_voice_mixer #(.CLK_HZ(CLK_HZ)) mixer(.clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),
   .note_number(note_number),.velocity(velocity),.expression_valid(expression_valid),.sample_valid(sample_valid),
   .mixed_sample(mixed_sample),.active_voice_count(active_voice_count));
endmodule
