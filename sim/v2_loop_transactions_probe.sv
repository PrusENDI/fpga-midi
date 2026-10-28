// Small-pin physical probe for the V2 32-slot recorder -> store -> scheduler
// hand-off.  It intentionally exposes only diagnostics; it is not the final
// V2 top or a board acceptance path.
module v2_loop_transactions_probe (
  input  logic clk_sys_100m,
  input  logic rst_n,
  input  logic run,
  input  logic [7:0] command,
  output logic [3:0] status
);
  logic [31:0] event_tick;
  logic [95:0] ingress_event;
  always_ff @(posedge clk_sys_100m or negedge rst_n) begin
    if (!rst_n) event_tick <= 0;
    else if (run) event_tick <= event_tick + 1'b1;
  end
  always_comb begin
    ingress_event = 96'd0;
    ingress_event[94:91] = 4'd1;
    ingress_event[90:88] = command[6:4];
    ingress_event[87:80] = event_tick[7:0];
    ingress_event[23:16] = command;
  end

  // The physical probe drives the same store hand-off with a compact event
  // source; the recorder/store joint behavior is covered by the RTL replay.
  logic record_event_ready, record_write_valid, record_write_ready;
  logic [95:0] record_write_data;
  logic [4:0] record_write_slot;
  logic recording;
  assign recording = run && command[0];
  assign record_event_ready = record_write_ready;
  assign record_write_valid = recording && command[7];
  assign record_write_data = ingress_event;
  always_ff @(posedge clk_sys_100m or negedge rst_n) begin
    if (!rst_n || !recording) record_write_slot <= 0;
    else if (record_write_valid && record_write_ready) record_write_slot <= record_write_slot + 1'b1;
  end

  logic ctrl_ready, ctrl_done, store_read_enable, store_read_valid, store_slot_valid;
  logic [2:0] ctrl_op, ctrl_track;
  assign ctrl_op = command[6:4];
  assign ctrl_track = command[6:4];
  logic [2:0] store_read_track; logic [4:0] store_read_index;
  logic [95:0] store_read_data;
  logic store_active_bank, store_shadow_bank, store_commit_pending, store_commit_ack, store_busy, store_active_valid;
  logic [35:0] store_record_count; logic [5:0] store_overflow;
  logic loop_boundary;
  v2_loop_event_store_dpb store (
    .clk(clk_sys_100m), .rst_n(rst_n), .abort(command[2]), .loop_boundary(loop_boundary),
    .ctrl_valid(command[3]), .ctrl_ready(ctrl_ready), .ctrl_op(ctrl_op), .ctrl_track(ctrl_track),
    .ctrl_done(ctrl_done), .write_valid(record_write_valid), .write_ready(record_write_ready),
    .write_track(ingress_event[90:88]), .write_slot(record_write_slot), .write_data(record_write_data),
    .read_enable(store_read_enable), .read_track(store_read_track), .read_index(store_read_index),
    .read_valid(store_read_valid), .read_slot_valid(store_slot_valid), .read_data(store_read_data),
    .active_bank(store_active_bank), .shadow_bank(store_shadow_bank),
    .commit_pending(store_commit_pending), .commit_ack(store_commit_ack), .busy(store_busy),
    .record_count(store_record_count), .overflow(store_overflow), .active_valid(store_active_valid)
  );

  logic scheduler_event_valid, scheduler_event_ready;
  logic [95:0] scheduler_event_data;
  v2_loop_scheduler scheduler (
    .clk(clk_sys_100m), .rst_n(rst_n), .run(run), .stop(!run), .flush(1'b0),
    .selected_track(3'd0), .loop_tick(event_tick[6:0]), .read_valid(store_read_valid),
    .read_slot_valid(store_slot_valid), .read_data(store_read_data), .read_enable(store_read_enable),
    .read_track(store_read_track), .read_index(store_read_index),
    .event_valid(scheduler_event_valid), .event_ready(scheduler_event_ready),
    .event_data(scheduler_event_data), .fault_valid(), .loop_boundary(loop_boundary)
  );
  assign scheduler_event_ready = 1'b1;
  always_comb begin
    // Fold every event lane into the observable diagnostic nibble so the
    // physical probe retains all six DPB lanes through synthesis.
    status[0] = store_active_valid ^ (^scheduler_event_data[15:0]);
    status[1] = store_busy ^ (^scheduler_event_data[31:16]);
    status[2] = store_commit_pending ^ (^scheduler_event_data[63:32]);
    status[3] = recording ^ command[1] ^ (^scheduler_event_data[95:64]);
  end
endmodule
