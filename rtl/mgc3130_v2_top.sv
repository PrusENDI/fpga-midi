// Independent V2 top-level boundary.
//
// The legacy mgc3130_uart_top remains the V1 baseline. This top owns the V2
// clock/reset, byte protocol endpoint, input/calibration/cursor path, separate
// LIVE and LOOP event paths, voice engine, reduced FX and I2S transmitter.
// USE_MGC_READER=0 is the deterministic simulation/P&R diagnostic mode; the
// board build enables the existing MGC3130 reader through the parameter.
module mgc3130_v2_top #(
    parameter integer USE_MGC_READER = 0,
    parameter integer UART_BAUD = 1_000_000,
    // The board build uses the explicit GW5A DPB state bank. A portable
    // simulation can override this to 0 and exercise the same engine with
    // the RTL memory model.
    parameter integer USE_GOWIN_RAM = 1,
    // The full Potts implementation is verified standalone. The default top
    // probe keeps it out of Gowin's 2000-iteration parser limit; a final build
    // must enable it after replacing the unbounded combinational scan with the
    // measured bounded implementation.
    parameter integer USE_POTTS = 0,
    // Timing-only structural probe option. Production/board builds leave it
    // disabled, so UART mode control remains the sole LOOP run source.
    parameter integer PRESERVE_LOOP_PLANE = 0,
    // Timing-only deterministic sensor activity. Production/board builds
    // leave this disabled and use the actual MGC3130 reader.
    parameter integer PRESERVE_INPUT_PLANE = 0,
    parameter integer PRESERVE_INPUT_VALID = 0
) (
    input  wire clk_50m,
    inout  wire mgc_sda,
    inout  wire mgc_scl,
    inout  wire mgc_ts,
    inout  wire mgc_mclr,
    input  wire uart_rx,
    output wire uart_tx,
    output wire pcm5102a_bck,
    output wire pcm5102a_lrck,
    output wire pcm5102a_din
);
    import v2_contract_pkg::*;

    logic clk_sys_100m, pll_locked, rst_sys_n;
    v2_clock_gen u_clock(.clk_in(clk_50m), .rst_n(1'b1),
                         .clk_sys_100m(clk_sys_100m), .pll_locked(pll_locked));
    logic [3:0] por_count = 4'd0;
    wire por_n = &por_count;
    always_ff @(posedge clk_sys_100m or negedge pll_locked) begin
        if (!pll_locked) por_count <= 4'd0;
        else if (!por_n) por_count <= por_count + 1'b1;
    end
    v2_reset_sync u_reset(.clk_sys_100m(clk_sys_100m), .rst_n(por_n),
                          .pll_locked(pll_locked), .rst_sys_n(rst_sys_n));

    logic sample_ce;
    logic [31:0] sample_index;
    v2_sample_scheduler u_scheduler(.clk_sys(clk_sys_100m), .rst_n(rst_sys_n),
                                    .sample_ce(sample_ce), .sample_index(sample_index));

    logic report_valid, xyz_valid, touch_valid, report_error, reader_busy;
    logic [31:0] touch_info;
    logic [15:0] x_position, y_position, z_position;
    logic [7:0] gesture_code, reader_error_code;
    logic [31:0] reader_debug_context;
    logic [15:0] reader_debug_mask;
    logic [7:0] reader_debug_size;

    generate
        if (USE_MGC_READER) begin : g_sensor
            mgc3130_reader #(.CLK_HZ(100_000_000), .I2C_HZ(100_000), .I2C_ADDR(7'h42))
            u_reader (
                .clk(clk_sys_100m), .rst_n(rst_sys_n), .i2c_sda(mgc_sda), .i2c_scl(mgc_scl),
                .mgc_ts(mgc_ts), .report_valid(report_valid), .xyz_valid(xyz_valid),
                .touch_valid(touch_valid), .touch_info(touch_info), .x_position(x_position),
                .y_position(y_position), .z_position(z_position), .gesture_code(gesture_code),
                .report_error(report_error), .error_code(reader_error_code), .busy(reader_busy),
                .debug_error_context(reader_debug_context), .debug_output_mask(reader_debug_mask),
                .debug_message_size(reader_debug_size)
            );
        end else begin : g_sensor_stub
            assign mgc_sda = 1'bz; assign mgc_scl = 1'bz; assign mgc_ts = 1'bz;
            if (PRESERVE_INPUT_PLANE) begin : g_input_probe
                assign report_valid = (sample_index[2:0] == 3'd0);
                // Exercise transport/touch metadata. The structural timing
                // probe normally keeps this invalid; a separate valid-input
                // diagnostic can enable the parameter explicitly.
                assign xyz_valid = PRESERVE_INPUT_VALID ? 1'b1 : 1'b0;
                assign touch_valid = report_valid;
                assign report_error = 1'b0;
                assign touch_info = {28'd0, sample_index[3:0]};
                assign x_position = 16'h8000 + sample_index[15:0];
                assign y_position = 16'h8000 + {8'd0, sample_index[7:0]};
                assign z_position = 16'h4000 + {8'd0, sample_index[7:0]};
                assign gesture_code = sample_index[7:0];
            end else begin : g_input_idle
                assign report_valid = 1'b0; assign xyz_valid = 1'b0;
                assign touch_valid = 1'b0; assign report_error = 1'b0;
                assign touch_info = 32'd0; assign x_position = 16'd0;
                assign y_position = 16'd0; assign z_position = 16'd0;
                assign gesture_code = 8'd0;
            end
            assign reader_error_code = 8'd0;
            assign reader_busy = 1'b0; assign reader_debug_context = 32'd0;
            assign reader_debug_mask = 16'd0; assign reader_debug_size = 8'd0;
        end
    endgenerate
    assign mgc_mclr = 1'bz;

    logic input_valid, input_xyz_valid, input_report_valid, input_report_error;
    logic input_touch_valid;
    logic [31:0] input_touch_info;
    logic [15:0] input_x, input_y, input_z, input_sequence;
    logic [7:0] input_gesture, input_epoch;
    logic signed [16:0] raw_x, raw_y;
    logic [16:0] raw_z;
    logic frame_valid, frame_gap, frame_saturated, frame_touch, frame_presence;
    logic frame_xyz_valid, frame_report_error, frame_touch_field_valid;
    logic [31:0] input_timestamp;
    logic [31:0] v2_touch_info;
    mgc3130_input_latch u_input_latch (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .report_valid(report_valid),
        .xyz_valid(xyz_valid), .report_error(report_error), .x_position(x_position),
        .y_position(y_position), .z_position(z_position), .gesture_code(gesture_code),
        .input_valid(input_valid), .xyz_valid_latched(input_xyz_valid), .x_latched(input_x),
        .y_latched(input_y), .z_latched(input_z), .gesture_latched(input_gesture),
        .touch_info(touch_info), .touch_valid(touch_valid),
        .report_valid_latched(input_report_valid), .report_error_latched(input_report_error),
        .touch_valid_latched(input_touch_valid), .touch_info_latched(input_touch_info),
        .v2_sequence(input_sequence), .v2_timestamp_ticks(input_timestamp), .v2_raw_x(raw_x),
        .v2_raw_y(raw_y), .v2_raw_z(raw_z), .v2_frame_valid(frame_valid), .v2_gap(frame_gap),
        .v2_saturated(frame_saturated), .v2_calibration_epoch(input_epoch), .v2_touch(frame_touch),
        .v2_presence(frame_presence), .v2_xyz_valid(frame_xyz_valid),
        .v2_report_error(frame_report_error), .v2_touch_field_valid(frame_touch_field_valid),
        .v2_touch_info(v2_touch_info), .v2_saturated_in(1'b0), .v2_sequence_valid(1'b0),
        .v2_sequence_in(16'd0)
    );

    logic profile_shadow_we, profile_commit;
    logic [2:0] profile_init;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) begin profile_init <= 0; profile_shadow_we <= 0; profile_commit <= 0; end
        else begin
            profile_shadow_we <= 1'b0; profile_commit <= 1'b0;
            if (profile_init == 0) begin profile_shadow_we <= 1'b1; profile_init <= 1; end
            else if (profile_init == 1) begin profile_commit <= 1'b1; profile_init <= 2; end
        end
    end

    logic signed [31:0] calibrated_x, calibrated_y, calibrated_z;
    logic [15:0] calibrated_sequence;
    logic [31:0] calibrated_timestamp;
    logic calibrated_touch, calibrated_presence, calibrated_valid, calibrated_saturated, calibrated_gap;
    logic [7:0] calibrated_epoch, calibration_reason;
    logic [7:0] active_epoch;
    logic active_profile_valid, calibration_strobe;
    logic signed [31:0] frame_cal_x, frame_cal_y, frame_cal_z;
    logic [15:0] frame_cal_sequence;
    logic [31:0] frame_cal_timestamp;
    logic [7:0] frame_cal_reason;
    logic frame_cal_valid;
    v2_input_calibration u_calibration (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(frame_valid),
        .raw_x(raw_x), .raw_y(raw_y), .raw_z(raw_z), .sequence_id(input_sequence),
        .timestamp_ticks(input_timestamp), .valid_xyz(frame_xyz_valid), .saturated(frame_saturated),
        .gap(frame_gap), .calibration_epoch_in(input_epoch), .touch(frame_touch),
        .presence(frame_presence), .profile_shadow_we(profile_shadow_we), .profile_commit(profile_commit),
        .shadow_neutral_x(0), .shadow_neutral_y(0), .shadow_neutral_z(0),
        .shadow_coupling_x(0), .shadow_coupling_y(0), .shadow_gain_x(32'sd65536),
        .shadow_gain_y(32'sd65536), .shadow_gain_z(32'sd65536),
        .shadow_ws_x_min(-32'sd32768), .shadow_ws_x_max(32'sd32767),
        .shadow_ws_y_min(-32'sd32768), .shadow_ws_y_max(32'sd32767),
        .shadow_ws_z_min(0), .shadow_ws_z_max(32'sd65535), .shadow_epoch(8'd0),
        .calibrated_x(calibrated_x), .calibrated_y(calibrated_y), .calibrated_z(calibrated_z),
        .output_sequence(calibrated_sequence), .output_timestamp_ticks(calibrated_timestamp),
        .output_touch(calibrated_touch), .output_presence(calibrated_presence),
        .output_valid(calibrated_valid), .output_saturated(calibrated_saturated),
        .output_gap(calibrated_gap), .output_calibration_epoch(calibrated_epoch),
        .calibration_reason(calibration_reason), .active_epoch(active_epoch),
        .active_profile_valid(active_profile_valid), .frame_output_strobe(calibration_strobe),
        .frame_calibrated_x(frame_cal_x), .frame_calibrated_y(frame_cal_y),
        .frame_calibrated_z(frame_cal_z), .frame_output_sequence(frame_cal_sequence),
        .frame_output_timestamp_ticks(frame_cal_timestamp), .frame_output_reason(frame_cal_reason),
        .frame_output_valid(frame_cal_valid)
    );

    logic valid_frame, lost_frame, degraded_frame, note_permitted;
    logic [15:0] gap_count;
    logic [7:0] valid_reason;
    v2_position_validity u_validity (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(calibration_strobe),
        .valid_xyz(frame_cal_valid), .saturated(calibrated_saturated), .gap(calibrated_gap),
        .sequence_id(frame_cal_sequence), .calibration_epoch(calibrated_epoch),
        .active_epoch(active_epoch), .active_profile_valid(active_profile_valid),
        .calibration_reason_in(frame_cal_reason), .frame_valid(valid_frame), .lost(lost_frame),
        .degraded(degraded_frame), .gap_count(gap_count), .calibration_reason(valid_reason),
        .note_permitted(note_permitted)
    );

    logic signed [31:0] cursor_x, cursor_y, cursor_z;
    logic [15:0] cursor_pitch, cursor_velocity, cursor_depth;
    logic [1:0] cursor_state;
    logic cursor_point_valid, cursor_rebased, cursor_stable_valid;
    logic signed [31:0] audio_cursor_x, audio_cursor_y, audio_cursor_z;
    logic [15:0] audio_pitch, audio_velocity, audio_depth, audio_sequence;
    logic audio_cursor_valid;
    logic [31:0] audio_timestamp;
    logic cursor_frame_done;
    v2_cursor_filter_timed u_cursor (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(calibration_strobe),
        .frame_x(frame_cal_x), .frame_y(frame_cal_y), .frame_z(frame_cal_z),
        .frame_valid(valid_frame), .frame_saturated(calibrated_saturated), .frame_gap(calibrated_gap),
        .frame_degraded(degraded_frame), .calibration_reason(valid_reason),
        .frame_sequence(frame_cal_sequence), .frame_timestamp(frame_cal_timestamp),
        .left_edge(1'b1), .sample_ce(sample_ce), .cursor_x(cursor_x), .cursor_y(cursor_y),
        .cursor_z(cursor_z), .normalized_pitch(cursor_pitch), .velocity_control(cursor_velocity),
        .depth_control(cursor_depth), .state(cursor_state), .point_valid(cursor_point_valid),
        .rebased(cursor_rebased), .stable_valid(cursor_stable_valid), .audio_cursor_x(audio_cursor_x),
        .audio_cursor_y(audio_cursor_y), .audio_cursor_z(audio_cursor_z), .audio_pitch(audio_pitch),
        .audio_velocity(audio_velocity), .audio_depth(audio_depth), .audio_valid(audio_cursor_valid),
        .audio_sequence(audio_sequence), .audio_timestamp(audio_timestamp), .frame_output_valid(cursor_frame_done)
    );

    logic [95:0] live_event_data, record_event_data /* synthesis syn_keep=1 */;
    logic voice_event_ready;
    logic live_event_valid /* synthesis syn_keep=1 */;
    logic live_event_ready;
    logic record_event_ready /* synthesis syn_keep=1 */;
    logic [3:0] live_event_type; logic [7:0] live_event_note, live_event_velocity;
    logic [15:0] live_event_count; logic [7:0] live_fault;
    logic live_left_edge, live_gate, live_active; logic [7:0] live_active_note;
    logic [31:0] mode_reg;
    wire mode_live = (mode_reg == LIVE);
    wire mode_record = (mode_reg == RECORD);
    wire mode_play = (mode_reg == PLAY);
    v2_live_rule_engine #(.PIPELINE_NOTE(1)) u_live (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(cursor_frame_done),
        .frame_valid(cursor_frame_done && cursor_point_valid && (cursor_state != 2'd3)), .frame_degraded(1'b0),
        .frame_gap(1'b0), .rebased(cursor_rebased), .left_edge(1'b1),
        .x(audio_cursor_x[15:0]), .y(audio_cursor_y[15:0]), .z(audio_cursor_z[15:0]),
        .touch(calibrated_touch), .bow(calibrated_presence), .tick(sample_index),
        .velocity_in(audio_velocity[7:0]), .brightness_in(audio_depth), .gain_in(16'hffff),
        .event_valid(live_event_valid), .event_ready(live_event_ready), .event_data(live_event_data),
        .event_type(live_event_type), .event_note(live_event_note), .event_velocity(live_event_velocity),
        .event_count(live_event_count), .fault_code(live_fault), .left_edge_armed(live_left_edge),
        .gate_state(live_gate), .active(live_active), .active_note(live_active_note)
    );

    logic record_start, record_stop, record_abort;
    logic record_write_valid /* synthesis syn_keep=1 */;
    logic record_write_ready /* synthesis syn_keep=1 */;
    logic [15:0] record_count /* synthesis syn_keep=1 */;
    logic [15:0] record_track_count [0:5] /* synthesis syn_keep=1 */;
    logic [7:0] record_fault /* synthesis syn_keep=1 */;
    logic record_left_edge, record_gate;
    logic recording /* synthesis syn_keep=1 */;
    logic [2:0] selected_track;
    logic loop_ctrl_valid, loop_ctrl_ready, loop_ctrl_done;
    logic [2:0] loop_ctrl_op, loop_ctrl_track;
    logic loop_ctrl_pending;
    logic [2:0] loop_ctrl_pending_op;
    wire loop_probe_run = (PRESERVE_LOOP_PLANE != 0) ? sample_index[0] : mode_play;
    wire loop_probe_record_start = (PRESERVE_LOOP_PLANE != 0) && (sample_index == 32'd16);
    wire loop_probe_record_stop = (PRESERVE_LOOP_PLANE != 0) && (sample_index == 32'd32);
    logic [95:0] recorder_event_data;
    logic [3:0] recorder_write_slot;
    assign recorder_event_data = {live_event_data[95:91], selected_track,
                                  live_event_data[87:0]};
    // The recorder increments track_event_count when it fills its holding
    // register. The store still needs the pre-increment slot number.
    assign recorder_write_slot = record_track_count[record_event_data[90:88]][3:0]
                               - (record_write_valid ? 4'd1 : 4'd0);
    (* keep_hierarchy = "yes" *)
    (* syn_noprune = 1 *)
    v2_loop_event_recorder u_recorder (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .record_start(record_start),
        .record_stop(record_stop), .abort(record_abort), .event_valid(live_event_valid),
        .event_ready(record_event_ready), .event_data(recorder_event_data),
        .event_tick(sample_index), .write_ready(record_write_ready),
        .loop_write_valid(record_write_valid), .loop_write_data(record_event_data),
        .read_req(1'b0), .read_track(3'd0), .read_index(16'd0), .read_valid(), .read_data(),
        .event_count(record_count), .track_event_count(record_track_count),
        .fault_code(record_fault), .left_edge_armed(record_left_edge),
        .gate_state(record_gate), .recording(recording)
    );
    assign live_event_ready = mode_live ? voice_event_ready : mode_record ? record_event_ready : 1'b0;

    logic [95:0] loop_event_data /* synthesis syn_keep=1 */;
    logic loop_event_valid /* synthesis syn_keep=1 */;
    logic loop_event_ready;
    logic loop_read_enable /* synthesis syn_keep=1 */;
    logic loop_read_valid /* synthesis syn_keep=1 */;
    logic loop_read_slot_valid /* synthesis syn_keep=1 */;
    logic [2:0] loop_read_track; logic [3:0] loop_read_index;
    logic [95:0] loop_read_data;
    logic loop_boundary /* synthesis syn_keep=1 */;
    logic loop_commit_pending /* synthesis syn_keep=1 */;
    logic loop_commit_ack, loop_busy;
    logic [29:0] loop_record_count /* synthesis syn_keep=1 */;
    logic [5:0] loop_overflow /* synthesis syn_keep=1 */;
    logic loop_active_valid /* synthesis syn_keep=1 */;
    (* keep_hierarchy = "yes" *)
    v2_loop_event_store u_store (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .abort(record_abort), .loop_boundary(loop_boundary),
        .ctrl_valid(loop_ctrl_valid), .ctrl_ready(loop_ctrl_ready), .ctrl_op(loop_ctrl_op),
        .ctrl_track(loop_ctrl_track), .ctrl_done(loop_ctrl_done),
        .write_valid(record_write_valid), .write_ready(record_write_ready),
        .write_track(record_event_data[90:88]),
        .write_slot(recorder_write_slot),
        .write_data(record_event_data), .read_enable(loop_read_enable), .read_track(loop_read_track),
        .read_index(loop_read_index), .read_valid(loop_read_valid), .read_slot_valid(loop_read_slot_valid),
        .read_data(loop_read_data), .active_bank(), .shadow_bank(), .commit_pending(loop_commit_pending),
        .commit_ack(loop_commit_ack), .busy(loop_busy), .record_count(loop_record_count),
        .overflow(loop_overflow), .active_valid(loop_active_valid)
    );
    (* keep_hierarchy = "yes" *)
    v2_loop_scheduler u_loop_sched (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .run(loop_probe_run), .stop(!loop_probe_run), .flush(1'b0),
        .selected_track(selected_track), .loop_tick(sample_index[6:0]), .read_valid(loop_read_valid),
        .read_slot_valid(loop_read_slot_valid), .read_data(loop_read_data),
        .read_enable(loop_read_enable), .read_track(loop_read_track), .read_index(loop_read_index),
        .event_valid(loop_event_valid), .event_ready(loop_event_ready), .event_data(loop_event_data),
        .fault_valid(), .loop_boundary(loop_boundary)
    );

    // Keep a narrow, low-fanout observability point for the independent V2
    // loop plane.  The production top does not route this signature to a
    // board pin; the timing probe observes it hierarchically.  Registering
    // the signature makes the recorder/store/scheduler state part of the
    // retained sequential cone without preserving the wide mode/control
    // buses that caused the timed19 fanout regression.
    (* keep = "true", syn_keep = 1, syn_noprune = 1 *)
    logic [17:0] v2_loop_debug_signature;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            v2_loop_debug_signature <= 18'd0;
        end else begin
            v2_loop_debug_signature <= {
                loop_ctrl_pending, loop_ctrl_valid, loop_ctrl_ready,
                loop_busy, loop_commit_pending, loop_active_valid,
                loop_boundary, loop_event_valid, loop_read_valid,
                loop_read_slot_valid, loop_read_enable,
                recording, record_write_valid, record_write_ready,
                record_left_edge, record_gate, (|record_count),
                (|loop_record_count), (|loop_overflow)
            };
        end
    end

    logic signed [15:0] potts_contour [0:127];
    logic potts_start, potts_busy, potts_done, potts_overflow, potts_backtrace_valid;
    logic potts_event_valid, potts_event_ready; logic [95:0] potts_event_data; logic [5:0] potts_event_count;
    genvar contour_i;
    generate for (contour_i=0; contour_i<128; contour_i=contour_i+1) begin : g_contour
        always_comb potts_contour[contour_i] = 16'sd0;
    end endgenerate
    generate if (USE_POTTS) begin : g_potts
    v2_potts_commit_fsm u_potts (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .start(potts_start), .lambda_q16(16'hffff),
        .rest_mask(128'd0), .contour(potts_contour), .busy(potts_busy), .progress(), .done(potts_done),
        .overflow(potts_overflow), .backtrace_valid(potts_backtrace_valid), .event_valid(potts_event_valid),
        .event_ready(potts_event_ready), .event_data(potts_event_data), .event_count(potts_event_count)
    );
    end else begin : g_potts_stub
        assign potts_busy = 1'b0; assign potts_done = 1'b0; assign potts_overflow = 1'b0;
        assign potts_backtrace_valid = 1'b0; assign potts_event_valid = 1'b0;
        assign potts_event_data = 96'd0; assign potts_event_count = 6'd0;
    end endgenerate

    logic voice_event_valid /* synthesis syn_keep=1 */, voice_overflow;
    logic [95:0] voice_event_data /* synthesis syn_keep=1 */;
    logic signed [15:0] voice_sample; logic voice_sample_valid;
    logic [31:0] voice_bitmap; logic [5:0] active_voice_count; logic [7:0] revoice_count;
    assign voice_event_valid = mode_live ? live_event_valid : mode_play ? loop_event_valid : potts_event_valid;
    assign voice_event_data = mode_live ? live_event_data : mode_play ? loop_event_data : potts_event_data;
    assign loop_event_ready = mode_play ? voice_event_ready : 1'b0;
    assign potts_event_ready = (!mode_live && !mode_play) ? voice_event_ready : 1'b0;
    v2_voice_engine_banked #(.VOICES(32), .USE_GOWIN_RAM(USE_GOWIN_RAM)) u_voice (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .event_valid(voice_event_valid), .event_ready(voice_event_ready),
        .event_data(voice_event_data), .mixed_sample(voice_sample), .sample_valid(voice_sample_valid),
        .active_bitmap(voice_bitmap), .voice_overflow(voice_overflow),
        .revoice_count(revoice_count), .active_voice_count(active_voice_count)
    );

    logic signed [15:0] fx_sample; logic [1:0] fx_status; logic fx_clip;
    v2_fx_lite #(.USE_GOWIN_RAM(1)) u_fx (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce), .audio_in(voice_sample),
        .audio_out(fx_sample), .fx_enable(1'b0), .fx_level(2'd0), .fx_gain_q16(18'h10000),
        .fx_cutoff_q16(16'hffff), .fx_delay_samples(10'd0), .fx_feedback_q15(16'd0),
        .fx_reverb_mix_q15(16'd0), .fx_status_level(fx_status), .fx_clip(fx_clip)
    );
    i2s_pcm5102a_tx #(.CLK_HZ(100_000_000), .SAMPLE_HZ(48_000)) u_i2s (
        .clk(clk_sys_100m), .rst(!rst_sys_n), .sample_valid(voice_sample_valid),
        .sample_in(fx_sample), .i2s_bck(pcm5102a_bck), .i2s_lrck(pcm5102a_lrck),
        .i2s_din(pcm5102a_din)
    );

    logic uart_byte_valid, uart_byte_error; logic [7:0] uart_byte;
    logic uart_tx_start, uart_tx_busy;
    uart_rx #(.CLK_HZ(100_000_000), .BAUD(UART_BAUD)) u_uart_rx (
        .clk(clk_sys_100m), .rst(!rst_sys_n), .rx(uart_rx), .valid(uart_byte_valid),
        .ready(1'b1), .data(uart_byte), .framing_error(uart_byte_error)
    );
    logic cmd_valid, cmd_ready, rsp_valid, rsp_ready;
    logic [7:0] cmd_op, cmd_address, cmd_sequence, rsp_sequence, rsp_status, rsp_error;
    logic [31:0] cmd_data, rsp_data;
    logic rsp_terminal, v2_tx_valid, v2_tx_ready; logic [7:0] v2_tx_byte, protocol_error;
    v2_uart_link u_v2_uart (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .rx_valid(uart_byte_valid), .rx_byte(uart_byte),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_op(cmd_op), .cmd_address(cmd_address),
        .cmd_sequence(cmd_sequence), .cmd_data(cmd_data), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_sequence(rsp_sequence), .rsp_status(rsp_status), .rsp_error(rsp_error), .rsp_data(rsp_data),
        .rsp_terminal(rsp_terminal), .tx_valid(v2_tx_valid), .tx_ready(v2_tx_ready), .tx_byte(v2_tx_byte),
        .rx_busy(), .tx_busy(), .protocol_error(protocol_error)
    );
    assign cmd_ready = !loop_ctrl_pending;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            mode_reg <= IDLE; rsp_valid <= 0; rsp_sequence <= 0; rsp_status <= 0;
            rsp_error <= V2_ERR_NONE; rsp_data <= 0; rsp_terminal <= 1'b1;
            record_start <= 0; record_stop <= 0; record_abort <= 0; potts_start <= 0;
            selected_track <= 3'd0;
            loop_ctrl_valid <= 1'b0; loop_ctrl_op <= 3'd0; loop_ctrl_track <= 3'd0;
            loop_ctrl_pending <= 1'b0; loop_ctrl_pending_op <= 3'd0;
        end else begin
            rsp_valid <= 1'b0; record_start <= 1'b0; record_stop <= 1'b0;
            record_abort <= 1'b0; potts_start <= 1'b0;
            loop_ctrl_valid <= loop_ctrl_pending;
            if (loop_probe_record_start) record_start <= 1'b1;
            if (loop_probe_record_stop) record_stop <= 1'b1;
            if (loop_ctrl_pending && loop_ctrl_ready) begin
                loop_ctrl_pending <= 1'b0;
                loop_ctrl_valid <= 1'b1;
            end
            if (loop_ctrl_done && (loop_ctrl_pending_op == 3'd5)) begin
                record_start <= 1'b1;
                mode_reg <= RECORD;
            end
            if (cmd_valid && cmd_ready) begin
                rsp_valid <= 1'b1; rsp_sequence <= cmd_sequence; rsp_status <= V2_ACK_ACCEPTED;
                rsp_error <= V2_ERR_NONE; rsp_data <= (cmd_address == V2_CSR_STATUS) ? mode_reg : 0;
                rsp_terminal <= 1'b1;
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_TRACK)
                    selected_track <= cmd_data[2:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_MODE) begin
                    mode_reg <= cmd_data[2:0];
                    if (cmd_data[2:0] == RECORD) record_start <= 1'b1;
                    if (cmd_data[2:0] != RECORD) record_stop <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_RECORD) begin
                    loop_ctrl_op <= 3'd5;
                    loop_ctrl_track <= selected_track;
                    loop_ctrl_pending_op <= 3'd5;
                    loop_ctrl_pending <= 1'b1;
                    record_stop <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_OVERDUB) begin
                    loop_ctrl_op <= 3'd0;
                    loop_ctrl_track <= selected_track;
                    loop_ctrl_pending_op <= 3'd0;
                    loop_ctrl_pending <= 1'b1;
                    record_stop <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_CLEAR_TRACK) begin
                    loop_ctrl_op <= 3'd1;
                    loop_ctrl_track <= cmd_data[2:0];
                    loop_ctrl_pending_op <= 3'd1;
                    loop_ctrl_pending <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_CLEAR_ALL) begin
                    loop_ctrl_op <= 3'd2;
                    loop_ctrl_track <= 3'd0;
                    loop_ctrl_pending_op <= 3'd2;
                    loop_ctrl_pending <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_COMMIT) begin
                    loop_ctrl_op <= 3'd3;
                    loop_ctrl_track <= 3'd0;
                    loop_ctrl_pending_op <= 3'd3;
                    loop_ctrl_pending <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_STOP) begin
                    mode_reg <= IDLE; record_abort <= 1'b1;
                    loop_ctrl_op <= 3'd4;
                    loop_ctrl_track <= 3'd0;
                    loop_ctrl_pending_op <= 3'd4;
                    loop_ctrl_pending <= 1'b1;
                    record_stop <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_COMMIT) potts_start <= 1'b1;
            end
        end
    end
    assign v2_tx_ready = !uart_tx_busy;
    assign uart_tx_start = v2_tx_valid && !uart_tx_busy;
    uart_tx #(.CLK_HZ(100_000_000), .BAUD(UART_BAUD)) u_uart_tx (
        .clk(clk_sys_100m), .rst(!rst_sys_n), .start(uart_tx_start), .data(v2_tx_byte),
        .tx(uart_tx), .busy(uart_tx_busy)
    );

    logic tlm_capture_valid, tlm_capture_ready, tlm_frame_valid, tlm_frame_ready, tlm_frame_last;
    logic [7:0] tlm_frame_byte, tlm_dropped;
    v2_telemetry_snapshot u_telemetry (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .capture_valid(tlm_capture_valid),
        .capture_ready(tlm_capture_ready), .capture_type(8'd1), .capture_sequence(audio_sequence),
        .capture_x(audio_cursor_x[15:0]), .capture_y(audio_cursor_y[15:0]),
        .capture_z(audio_cursor_z[15:0]), .capture_note(live_active_note),
        .capture_flags({1'b0, recording, loop_active_valid, loop_commit_pending, cursor_rebased,
                        calibrated_presence, record_fault[1:0]}), .capture_tick(sample_index[7:0]),
        .capture_voice_bitmap(voice_bitmap), .capture_fifo_level(record_count[7:0]),
        .capture_fault_code(protocol_error | record_fault),
        .frame_valid(tlm_frame_valid), .frame_ready(tlm_frame_ready), .frame_byte(tlm_frame_byte),
        .frame_last(tlm_frame_last), .dropped_captures(tlm_dropped)
    );
    assign tlm_capture_valid = sample_ce && audio_cursor_valid;
    assign tlm_frame_ready = 1'b0;
endmodule
