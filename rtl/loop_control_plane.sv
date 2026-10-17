// Byte-level UART control plane and typed-event datapath. Board UART RX/TX and
// sensor/voice adapters are intentionally outside this independently tested top.
module loop_control_plane #(
    parameter integer CLK_HZ=50_000_000,
    parameter integer USE_GOWIN_RAM=1,
    parameter integer OP_TIMEOUT_CYCLES=CLK_HZ,
    parameter integer BOUNDARY_TIMEOUT_CYCLES=1_700_000_000,
    parameter integer RX_TIMEOUT_CYCLES=500000
)(
    input wire clk,rst_n,
    input wire rx_valid,output wire rx_ready,input wire [7:0] rx_data,
    output wire tx_valid,input wire tx_ready,output wire [7:0] tx_data,
    input wire record_start,
    input wire in_valid,output wire in_ready,input wire [63:0] in_data,
    input wire record_in_valid,output wire record_in_ready,input wire [63:0] record_in_data,
    input wire adapter_idle,
    output wire out_valid,input wire out_ready,output wire [63:0] out_data,
    output wire [3:0] mode,output wire [1:0] selected_track,
    output wire [15:0] bpm_shadow,active_bpm,start_enter,start_exit,
    output wire [6:0] loop_tick,output wire active_valid,fault_latched,
    output wire live_enable,record_enable,play_enable,
    output wire flush_events,
    output wire [2:0] router_debug,
    output wire [7:0] router_status,
    input wire [15:0] report_count,xyz_count,sample_count,
    input wire [7:0] note_on_count,
    input wire [2:0] active_voice_count,
    input wire [7:0] diag_flags
);
    wire req_valid,req_ready,req_write,rsp_valid,rsp_ready;
    wire [7:0] req_addr,rsp_status;wire [31:0] req_wdata,rsp_rdata;
    wire urgent_stop;
    command_mailbox #(.RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)) mailbox (
        .clk(clk),.rst_n(rst_n),.rx_valid(rx_valid),.rx_ready(rx_ready),.rx_data(rx_data),
        .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),
        .csr_valid(req_valid),.csr_ready(req_ready),.csr_write(req_write),.csr_addr(req_addr),.csr_wdata(req_wdata),
        .csr_rsp_valid(rsp_valid),.csr_rsp_ready(rsp_ready),.csr_rsp_status(rsp_status),.csr_rsp_rdata(rsp_rdata),
        .urgent_stop(urgent_stop));
    wire cmd_valid,cmd_ready,cmd_rsp_valid,cmd_rsp_ready;
    wire [7:0] cmd_opcode,cmd_rsp_status;wire [15:0] cmd_arg0,cmd_arg1;wire [31:0] cmd_rsp_data;
    wire store_commit_pending;
    control_csr csr (
        .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_addr(req_addr),.req_wdata(req_wdata),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_status(rsp_status),.rsp_rdata(rsp_rdata),
        .cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_opcode(cmd_opcode),.cmd_arg0(cmd_arg0),.cmd_arg1(cmd_arg1),
        .cmd_rsp_valid(cmd_rsp_valid),.cmd_rsp_ready(cmd_rsp_ready),.cmd_rsp_status(cmd_rsp_status),.cmd_rsp_data(cmd_rsp_data),
        .mode(mode),.selected_track(selected_track),.bpm_shadow(bpm_shadow),.active_bpm(active_bpm),
        .start_enter(start_enter),.start_exit(start_exit),.loop_tick(loop_tick),.active_valid(active_valid),
        .commit_pending(store_commit_pending),.fault_latched(fault_latched),
        .report_count(report_count),.xyz_count(xyz_count),.sample_count(sample_count),
        .note_on_count(note_on_count),.active_voice_count(active_voice_count),.diag_flags(diag_flags),
        .router_status(router_status));
    wire store_ctrl_valid,store_ctrl_ready,store_ctrl_done,store_commit_ack,store_busy;
    wire [2:0] store_ctrl_op;wire [1:0] store_ctrl_track;
    wire [19:0] store_record_count;wire [3:0] store_overflow;
    wire store_abort,store_boundary,scheduler_run,scheduler_stop,scheduler_reset,boundary_ready;
    wire kill_valid,kill_ready,router_idle,record_accepted,record_overflow;
    wire sixteenth_ce,loop_boundary,scheduler_fault;
    mode_manager #(.OP_TIMEOUT_CYCLES(OP_TIMEOUT_CYCLES),.BOUNDARY_TIMEOUT_CYCLES(BOUNDARY_TIMEOUT_CYCLES)) manager (
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_opcode(cmd_opcode),.cmd_arg0(cmd_arg0),.cmd_arg1(cmd_arg1),
        .rsp_valid(cmd_rsp_valid),.rsp_ready(cmd_rsp_ready),.rsp_status(cmd_rsp_status),.rsp_data(cmd_rsp_data),
        .urgent_stop(urgent_stop),.record_start(record_start),.sixteenth_ce(sixteenth_ce),.loop_tick(loop_tick),.loop_boundary(loop_boundary),
        .scheduler_active_bpm(active_bpm),.scheduler_fault(scheduler_fault),
        .store_ctrl_ready(store_ctrl_ready),.store_ctrl_done(store_ctrl_done),.store_commit_pending(store_commit_pending),
        .store_commit_ack(store_commit_ack),.store_active_valid(active_valid),.store_busy(store_busy),
        .store_record_count(store_record_count),.store_overflow(store_overflow | {4{record_overflow}}),
        .router_idle(router_idle && adapter_idle),.record_accepted(record_accepted),.store_ctrl_valid(store_ctrl_valid),
        .store_ctrl_op(store_ctrl_op),.store_ctrl_track(store_ctrl_track),.store_abort(store_abort),.store_boundary(store_boundary),
        .scheduler_run(scheduler_run),.scheduler_stop(scheduler_stop),.scheduler_reset(scheduler_reset),.boundary_ready(boundary_ready),
        .kill_valid(kill_valid),.kill_ready(kill_ready),.flush_events(flush_events),.mode(mode),.selected_track(selected_track),
        .bpm_shadow(bpm_shadow),.start_enter(start_enter),.start_exit(start_exit),
        .live_enable(live_enable),.record_enable(record_enable),.play_enable(play_enable),.fault_latched(fault_latched));
    reg urgent_d;
    always @(posedge clk or negedge rst_n) if(!rst_n) urgent_d<=0;else urgent_d<=urgent_stop;
    wire urgent_edge=urgent_stop && !urgent_d;
    wire read_enable,read_valid,read_slot_valid;wire [5:0] read_index;wire [63:0] read_data;
    wire write_valid,write_ready;wire [1:0] write_track;wire [3:0] write_slot;wire [63:0] write_data;
    loop_event_store #(.USE_GOWIN_RAM(USE_GOWIN_RAM)) store (
        .clk(clk),.rst_n(rst_n),.abort(store_abort | urgent_edge),.loop_boundary(store_boundary),
        .ctrl_valid(store_ctrl_valid),.ctrl_ready(store_ctrl_ready),.ctrl_op(store_ctrl_op),.ctrl_track(store_ctrl_track),.ctrl_done(store_ctrl_done),
        .write_valid(write_valid),.write_ready(write_ready),.write_track(write_track),.write_slot(write_slot),.write_data(write_data),
        .read_enable(read_enable),.read_index(read_index),.read_valid(read_valid),.read_slot_valid(read_slot_valid),.read_data(read_data),
        .active_bank(),.shadow_bank(),.commit_pending(store_commit_pending),.commit_ack(store_commit_ack),
        .busy(store_busy),.record_count(store_record_count),.overflow(store_overflow),.active_valid(active_valid));
    wire sched_valid,sched_ready;wire [63:0] sched_data;
    loop_scheduler #(.CLK_HZ(CLK_HZ)) scheduler (
        .clk(clk),.rst_n(rst_n && !scheduler_reset),.run(scheduler_run),.stop(scheduler_stop | urgent_edge),
        .flush(1'b0),.reset_position(1'b0),.boundary_ready(boundary_ready),.bpm_value(bpm_shadow),
        .read_enable(read_enable),.read_index(read_index),.read_valid(read_valid),.read_slot_valid(read_slot_valid),.read_data(read_data),
        .event_valid(sched_valid),.event_ready(sched_ready),.event_data(sched_data),.sixteenth_ce(sixteenth_ce),
        .loop_tick(loop_tick),.loop_boundary(loop_boundary),.stall(),.fault_valid(scheduler_fault),.fault_code(),.fault_info(),
        .heartbeat_toggle(),.active_bpm(active_bpm));
    wire ingress_live_valid,ingress_live_ready;wire [63:0] ingress_live_data;
    wire ingress_record_valid,ingress_record_ready;wire [63:0] ingress_record_data;
    wire [15:0] ingress_live_level,ingress_record_level;wire ingress_mod_pending;
    performance_event_ingress #(.DEPTH(16)) ingress (
        .clk(clk),.rst_n(rst_n),.flush(flush_events | urgent_edge),
        .live_in_valid(in_valid),.live_in_ready(in_ready),.live_in_data(in_data),
        .live_out_valid(ingress_live_valid),.live_out_ready(ingress_live_ready),.live_out_data(ingress_live_data),
        .record_in_valid(record_in_valid),.record_in_ready(record_in_ready),.record_in_data(record_in_data),
        .record_out_valid(ingress_record_valid),.record_out_ready(ingress_record_ready),.record_out_data(ingress_record_data),
        .modulation_in_valid(1'b0),.modulation_in_ready(),.modulation_in_data(64'd0),
        .modulation_out_valid(),.modulation_out_ready(1'b0),.modulation_out_data(),
        .live_level(ingress_live_level),.record_level(ingress_record_level),.modulation_pending(ingress_mod_pending));
    performance_event_router #(.SPLIT_INPUTS(1)) router (
        .clk(clk),.rst_n(rst_n),.flush(flush_events | urgent_edge),.live_enable(live_enable),.record_enable(record_enable),.play_enable(play_enable),
        .selected_track(selected_track),.loop_tick(loop_tick),.store_record_count(store_record_count),
        .in_valid(1'b0),.in_ready(),.in_data(64'd0),
        .live_in_valid(ingress_live_valid),.live_in_ready(ingress_live_ready),.live_in_data(ingress_live_data),
        .record_in_valid(ingress_record_valid),.record_in_ready(ingress_record_ready),.record_in_data(ingress_record_data),
        .sched_valid(sched_valid),.sched_ready(sched_ready),.sched_data(sched_data),
        .kill_valid(kill_valid),.kill_ready(kill_ready),.out_valid(out_valid),.out_ready(out_ready),.out_data(out_data),
        .write_valid(write_valid),.write_ready(write_ready),.write_track(write_track),.write_slot(write_slot),.write_data(write_data),
        .idle(router_idle),.record_accepted(record_accepted),.record_overflow(record_overflow),
        .pending_debug(router_debug));
    // One-byte read-only snapshot for board bring-up.  It distinguishes a
    // router arbitration gate from a stuck adapter/mux handshake.
    // CSR 0x44 exposes independent queue occupancy.  Pending arbitration and
    // kill state remain in the audio diagnostic byte and are never inferred
    // from a single shared ready bit.
    assign router_status={ingress_record_level[3:0],ingress_live_level[3:0]};
endmodule
