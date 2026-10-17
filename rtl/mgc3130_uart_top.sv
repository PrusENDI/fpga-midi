module mgc3130_uart_top #(
    // Build the audio path by default. Set to 0 for the separate ASCII
    // diagnostic bitstream used by capture_mgc3130.py.
    parameter integer AUDIO_STREAM = 0,
    parameter integer AUDIO_OUTPUT = 1,
    parameter integer LOOP_CONTROL_ENABLE = 0,
    parameter integer USE_GOWIN_UART_FIFO = 0,
    parameter integer USE_REF_UART_RX = 0,
    parameter integer RESET_LOW_MS = 250,
    parameter integer STARTUP_WAIT_MS = 2000
) (
    input  wire clk_50m,
    inout  wire mgc_sda,
    inout  wire mgc_scl,
    inout  wire mgc_ts,
    inout  wire mgc_mclr,
    output wire uart_tx,
    input wire uart_rx,
    output wire pcm5102a_bck,
    output wire pcm5102a_lrck,
    output wire pcm5102a_din
);
    wire mgc_mclr_drive_low;
    wire mgc_ready;
    assign mgc_mclr = mgc_mclr_drive_low ? 1'b0 : 1'bz;

    mgc3130_reset_seq #(.CLK_HZ(50_000_000), .RESET_LOW_MS(RESET_LOW_MS), .STARTUP_WAIT_MS(STARTUP_WAIT_MS)) u_reset_seq (
        .clk(clk_50m), .mclr_drive_low(mgc_mclr_drive_low), .ready(mgc_ready)
    );

    wire        report_valid;
    wire        xyz_valid;
    wire        touch_valid;
    wire [31:0] touch_info;
    wire [15:0] x_position;
    wire [15:0] y_position;
    wire [15:0] z_position;
    wire [7:0]  gesture_code;
    wire        report_error;
    wire [3:0]  error_code;
    wire        reader_busy;
    wire [31:0] debug_error_context;
    wire [15:0] debug_output_mask;
    wire [7:0] debug_message_size;
    wire synth_input_valid;
    wire synth_xyz_valid;
    wire [15:0] synth_x, synth_y, synth_z;
    wire [7:0] synth_gesture;
    wire synth_report_valid_latched;
    wire synth_report_error_latched;
    wire synth_touch_valid_latched;
    wire [31:0] synth_touch_info_latched;
    wire synth_recording;
    wire synth_pattern_commit;
    wire synth_cell_event;
    wire synth_note_on;
    wire synth_note_off;
    wire synth_expression_valid;
    wire [4:0] synth_time_cell;
    wire [6:0] synth_note_number;
    wire [7:0] synth_velocity;
    wire synth_sample_valid;
    wire signed [15:0] synth_mixed_sample;
    wire [2:0] synth_active_voice_count;
    wire debug_uart_tx;
    wire audio_uart_tx;
    wire control_uart_tx;
    wire control_uart_busy;
    wire loop_tx_valid, loop_tx_ready;
    wire [7:0] loop_tx_data;
    wire [3:0] loop_mode;
    wire [1:0] loop_selected_track;
    wire [6:0] loop_tick;
    wire loop_active_valid, loop_fault_latched;
    wire signed [15:0] loop_mixed_sample;
    wire loop_sample_valid;
    wire [2:0] loop_active_voice_count;
    wire [15:0] loop_report_count, loop_xyz_count;
    wire loop_rx_overflow, loop_rx_framing_error, loop_adapter_overflow;
    wire banner_tx, banner_busy;
    wire control_serializer_ready;
    wire loop_enable_bit;
    assign loop_enable_bit = (LOOP_CONTROL_ENABLE != 0);
    wire signed [15:0] selected_mixed_sample;
    wire selected_sample_valid;
    assign selected_mixed_sample = LOOP_CONTROL_ENABLE ? loop_mixed_sample : synth_mixed_sample;
    assign selected_sample_valid = LOOP_CONTROL_ENABLE ? loop_sample_valid : synth_sample_valid;
    wire command_rx_valid,command_rx_error;
    wire [7:0] command_rx_data;
    // Physical RX is now reserved on B3. It is exposed to the future command
    // mailbox integration while the legacy audio/ASCII paths remain unchanged.
    uart_rx #(.CLK_HZ(50_000_000),.BAUD(115_200)) u_command_rx (
        .clk(clk_50m),.rst(!mgc_ready),.rx(uart_rx),.valid(command_rx_valid),
        .ready(1'b1),.data(command_rx_data),.framing_error(command_rx_error)
    );
    wire i2s_bck;
    wire i2s_lrck;
    wire i2s_din;

    mgc3130_reader #(
        .CLK_HZ   (50_000_000),
        .I2C_HZ   (100_000),
        .I2C_ADDR (7'h42)
    ) u_reader (
        .clk          (clk_50m),
        .rst_n        (mgc_ready),
        .i2c_sda      (mgc_sda),
        .i2c_scl      (mgc_scl),
        .mgc_ts       (mgc_ts),
        .report_valid (report_valid),
        .xyz_valid    (xyz_valid),
        .touch_valid  (touch_valid),
        .touch_info   (touch_info),
        .x_position   (x_position),
        .y_position   (y_position),
        .z_position   (z_position),
        .gesture_code (gesture_code),
        .report_error (report_error),
        .error_code   (error_code),
        .busy         (reader_busy),
        .debug_error_context (debug_error_context),
        .debug_output_mask (debug_output_mask),
        .debug_message_size (debug_message_size)
    );

    mgc3130_input_latch u_input_latch (
        .clk(clk_50m), .rst_n(mgc_ready),
        .report_valid(report_valid), .xyz_valid(xyz_valid),
        .report_error(report_error), .x_position(x_position),
        .touch_valid(touch_valid), .touch_info(touch_info),
        .y_position(y_position), .z_position(z_position),
        .gesture_code(gesture_code), .input_valid(synth_input_valid),
        .xyz_valid_latched(synth_xyz_valid), .x_latched(synth_x),
        .y_latched(synth_y), .z_latched(synth_z),
        .gesture_latched(synth_gesture),
        .report_valid_latched(synth_report_valid_latched),
        .report_error_latched(synth_report_error_latched),
        .touch_valid_latched(synth_touch_valid_latched),
        .touch_info_latched(synth_touch_info_latched)
    );

    mgc3130_pattern_input u_pattern_input (
        .clk             (clk_50m),
        .rst_n           (mgc_ready),
        .report_valid    (synth_input_valid),
        .xyz_valid       (synth_xyz_valid),
        .report_error    (1'b0),
        .x_position      (synth_x),
        .y_position      (synth_y),
        .z_position      (synth_z),
        .recording       (synth_recording),
        .pattern_commit  (synth_pattern_commit),
        .cell_event      (synth_cell_event),
        .note_on         (synth_note_on),
        .note_off        (synth_note_off),
        .expression_valid(synth_expression_valid),
        .time_cell       (synth_time_cell),
        .note_number     (synth_note_number),
        .velocity        (synth_velocity)
    );

    mgc3130_voice_mixer u_voice_mixer (
        .clk                (clk_50m),
        .rst_n              (mgc_ready),
        .note_on            (synth_note_on),
        .note_off           (synth_note_off),
        .note_number        (synth_note_number),
        .velocity           (synth_velocity),
        .expression_valid   (synth_expression_valid),
        .sample_valid       (synth_sample_valid),
        .mixed_sample       (synth_mixed_sample),
        .active_voice_count (synth_active_voice_count)
    );

    mgc3130_loop_control_path #(
        .CLK_HZ(50_000_000), .BAUD(115_200), .USE_GOWIN_RAM(1),
        .USE_GOWIN_FIFO(USE_GOWIN_UART_FIFO), .USE_REF_UART_RX(USE_REF_UART_RX)
    ) u_loop_control_path (
        .clk(clk_50m), .rst_n(mgc_ready), .uart_rx(uart_rx),
        .tx_valid(loop_tx_valid), .tx_ready(control_serializer_ready), .tx_data(loop_tx_data),
        .report_valid(report_valid), .xyz_valid(xyz_valid), .report_error(report_error),
        .touch_valid(touch_valid), .touch_info(touch_info),
        .x_position(x_position), .y_position(y_position), .z_position(z_position),
        .gesture_code(gesture_code), .mode(loop_mode),
        .selected_track(loop_selected_track), .loop_tick(loop_tick),
        .active_valid(loop_active_valid), .fault_latched(loop_fault_latched),
        .rx_overflow(loop_rx_overflow), .rx_framing_error(loop_rx_framing_error),
        .adapter_overflow(loop_adapter_overflow),
        .mixed_sample(loop_mixed_sample), .sample_valid(loop_sample_valid),
        .active_voice_count(loop_active_voice_count),
        .report_count(loop_report_count), .xyz_count(loop_xyz_count)
    );
    uart_byte_serializer #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_control_tx (
        .clk(clk_50m), .rst(!mgc_ready), .in_valid(loop_tx_valid && LOOP_CONTROL_ENABLE && !banner_busy),
        .in_ready(loop_tx_ready), .in_data(loop_tx_data), .tx(control_uart_tx),
        .busy(control_uart_busy)
    );

    // The Loop build emits this one-shot marker as soon as the MGC startup
    // reset completes.  It makes a wrong bitstream, wrong COM channel, or
    // missing C3 connection immediately distinguishable from a protocol bug.
    uart_banner_tx #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_loop_banner (
        .clk   (clk_50m),
        .rst   (!mgc_ready || !loop_enable_bit),
        .enable(loop_enable_bit),
        .tx    (banner_tx),
        .busy  (banner_busy)
    );
    assign control_serializer_ready = LOOP_CONTROL_ENABLE && !banner_busy && loop_tx_ready;

    // ASCII snapshots every 20 ms: fast enough to capture the hand trajectory
    // while remaining below the 115200-baud UART line capacity.
    // One 85-character report takes about 7.4 ms at 115200 8N1.
    localparam integer STATUS_PERIOD = 1_000_000;
    reg [31:0] st_timer;
    reg [6:0] st_index;
    reg st_sending;
    reg st_start;
    reg [7:0] st_data;
    reg st_ts_latched;
    reg st_mclr_latched;
    reg st_sda_latched;
    reg st_scl_latched;
    reg [7:0] valid_count;
    reg [7:0] error_count;
    reg [7:0] valid_latched;
    reg [7:0] error_latched;
    reg [3:0] code_latched;
    reg [15:0] x_latched, y_latched, z_latched;
    reg [7:0] gesture_latched;
    reg position_valid_latched;
    reg [31:0] context_latched;
    reg [15:0] mask_latched;
    reg [7:0] size_latched;
    reg synth_recording_latched;
    reg [4:0] synth_cell_latched;
    reg [6:0] synth_note_latched;
    reg [7:0] synth_velocity_latched;
    reg [2:0] synth_active_latched;
    wire st_busy;
    wire ts_level;
    wire mclr_level;
    wire sda_level;
    wire scl_level;
    assign ts_level = mgc_ts;
    assign mclr_level = mgc_mclr;
    assign sda_level = mgc_sda;
    assign scl_level = mgc_scl;

    function [7:0] status_char;
        input [6:0] n;
        begin
            case (n)
                0: status_char = "T"; 1: status_char = "S";
                2: status_char = "="; 3: status_char = st_ts_latched ? "1" : "0";
                4: status_char = " "; 5: status_char = "M";
                6: status_char = "="; 7: status_char = st_mclr_latched ? "1" : "0";
                8: status_char = " "; 9: status_char = "S";
                10: status_char = "="; 11: status_char = st_sda_latched ? "1" : "0";
                12: status_char = " "; 13: status_char = "C";
                14: status_char = "="; 15: status_char = st_scl_latched ? "1" : "0";
                16: status_char = " "; 17: status_char = "V";
                18: status_char = "=";
                19: status_char = hex_char(valid_latched[7:4]);
                20: status_char = hex_char(valid_latched[3:0]);
                21: status_char = " "; 22: status_char = "E";
                23: status_char = "=";
                24: status_char = hex_char(error_latched[7:4]);
                25: status_char = hex_char(error_latched[3:0]);
                26: status_char = " "; 27: status_char = "K";
                28: status_char = "="; 29: status_char = hex_char(code_latched);
                30: status_char = " "; 31: status_char = "X";
                32: status_char = "=";
                33: status_char = hex_char(x_latched[15:12]);
                34: status_char = hex_char(x_latched[11:8]);
                35: status_char = hex_char(x_latched[7:4]);
                36: status_char = hex_char(x_latched[3:0]);
                37: status_char = " "; 38: status_char = "Y";
                39: status_char = "=";
                40: status_char = hex_char(y_latched[15:12]);
                41: status_char = hex_char(y_latched[11:8]);
                42: status_char = hex_char(y_latched[7:4]);
                43: status_char = hex_char(y_latched[3:0]);
                44: status_char = " "; 45: status_char = "Z";
                46: status_char = "=";
                47: status_char = hex_char(z_latched[15:12]);
                48: status_char = hex_char(z_latched[11:8]);
                49: status_char = hex_char(z_latched[7:4]);
                50: status_char = hex_char(z_latched[3:0]);
                51: status_char = " "; 52: status_char = "G";
                53: status_char = "=";
                54: status_char = hex_char(gesture_latched[7:4]);
                55: status_char = hex_char(gesture_latched[3:0]);
                56: status_char = " "; 57: status_char = "P";
                58: status_char = "=";
                59: status_char = position_valid_latched ? "1" : "0";
                60: status_char = " "; 61: status_char = "D";
                62: status_char = "=";
                63: status_char = hex_char(context_latched[31:28]);
                64: status_char = hex_char(context_latched[27:24]);
                65: status_char = hex_char(context_latched[23:20]);
                66: status_char = hex_char(context_latched[19:16]);
                67: status_char = hex_char(context_latched[15:12]);
                68: status_char = hex_char(context_latched[11:8]);
                69: status_char = hex_char(context_latched[7:4]);
                70: status_char = hex_char(context_latched[3:0]);
                71: status_char = " "; 72: status_char = "F";
                73: status_char = "=";
                74: status_char = hex_char(mask_latched[15:12]);
                75: status_char = hex_char(mask_latched[11:8]);
                76: status_char = hex_char(mask_latched[7:4]);
                77: status_char = hex_char(mask_latched[3:0]);
                78: status_char = " "; 79: status_char = "L";
                80: status_char = "=";
                81: status_char = hex_char(size_latched[7:4]);
                82: status_char = hex_char(size_latched[3:0]);
                83: status_char = " "; 84: status_char = "R";
                85: status_char = "="; 86: status_char = synth_recording_latched ? "1" : "0";
                87: status_char = " "; 88: status_char = "N";
                89: status_char = "="; 90: status_char = hex_char(synth_note_latched[6:4]);
                91: status_char = hex_char(synth_note_latched[3:0]);
                92: status_char = " "; 93: status_char = "A";
                94: status_char = "="; 95: status_char = hex_char({1'b0, synth_active_latched});
                96: status_char = 8'h0d; 97: status_char = 8'h0a;
                default: status_char = 8'h0a;
            endcase
        end
    endfunction

    function [7:0] hex_char;
        input [3:0] n;
        begin
            if (n < 10)
                hex_char = 8'h30 + {4'b0000, n};
            else
                hex_char = 8'h41 + {4'b0000, (n - 4'd10)};
        end
    endfunction

    uart_tx #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_status_tx (
        .clk(clk_50m), .rst(!mgc_ready), .start(st_start),
        .data(st_data), .tx(debug_uart_tx), .busy(st_busy)
    );


    // Keep the audio wire format and line rate explicit at the integration
    // boundary.  The transmitter module defaults to the legacy 115200 baud
    // diagnostic rate; relying on those defaults silently makes an
    // AUDIO_STREAM=1 bitstream incompatible with the PC receiver.
    mgc3130_audio_uart_tx #(
        .CLK_HZ     (50_000_000),
        .BAUD       (921_600),
        .SAMPLE_HZ  (48_000),
        .STREAM_HZ  (48_000)
    ) u_audio_uart_tx (
        .clk(clk_50m), .rst(!mgc_ready),
        .sample_valid(selected_sample_valid),
        .mixed_sample(selected_mixed_sample),
        .tx(audio_uart_tx), .busy()
    );

    i2s_pcm5102a_tx #(
        .CLK_HZ    (50_000_000),
        .SAMPLE_HZ (48_000)
    ) u_i2s_pcm5102a_tx (
        .clk          (clk_50m),
        .rst          (!mgc_ready),
        .sample_valid (selected_sample_valid),
        .sample_in    (selected_mixed_sample),
        .i2s_bck      (i2s_bck),
        .i2s_lrck     (i2s_lrck),
        .i2s_din      (i2s_din)
    );

    assign pcm5102a_bck  = AUDIO_OUTPUT ? i2s_bck  : 1'b0;
    assign pcm5102a_lrck = AUDIO_OUTPUT ? i2s_lrck : 1'b0;
    assign pcm5102a_din  = AUDIO_OUTPUT ? i2s_din  : 1'b0;

    assign uart_tx = LOOP_CONTROL_ENABLE ? (banner_busy ? banner_tx : control_uart_tx) :
                     (AUDIO_STREAM ? audio_uart_tx : debug_uart_tx);

    always @(posedge clk_50m or negedge mgc_ready) begin
        if (!mgc_ready) begin
            st_timer <= 0; st_index <= 0; st_sending <= 0;
            st_start <= 0; st_data <= 0;
            st_ts_latched <= 1'b1; st_mclr_latched <= 1'b0;
            st_sda_latched <= 1'b1; st_scl_latched <= 1'b1;
            valid_count <= 0; error_count <= 0;
            valid_latched <= 0; error_latched <= 0;
            code_latched <= 0;
            x_latched <= 0; y_latched <= 0; z_latched <= 0;
            gesture_latched <= 0; position_valid_latched <= 0;
            context_latched <= 0;
            mask_latched <= 0; size_latched <= 0;
            synth_recording_latched <= 0;
            synth_cell_latched <= 0; synth_note_latched <= 0;
            synth_velocity_latched <= 0; synth_active_latched <= 0;
        end else begin
            if (report_valid && !report_error) valid_count <= valid_count + 1'b1;
            if (report_error) error_count <= error_count + 1'b1;
            st_start <= 0;
            if (!LOOP_CONTROL_ENABLE && !st_sending) begin
                if (st_timer == STATUS_PERIOD - 1) begin
                    st_timer <= 0; st_index <= 0;
                    st_ts_latched <= ts_level;
                    st_mclr_latched <= mclr_level;
                    st_sda_latched <= sda_level;
                    st_scl_latched <= scl_level;
                    valid_latched <= valid_count;
                    error_latched <= error_count;
                    code_latched <= error_code;
                    x_latched <= x_position; y_latched <= y_position;
                    z_latched <= z_position; gesture_latched <= gesture_code;
                    position_valid_latched <= xyz_valid;
                    context_latched <= debug_error_context;
                    mask_latched <= debug_output_mask; size_latched <= debug_message_size;
                    synth_recording_latched <= synth_recording;
                    synth_cell_latched <= synth_time_cell;
                    synth_note_latched <= synth_note_number;
                    synth_velocity_latched <= synth_velocity;
                    synth_active_latched <= synth_active_voice_count;
                    st_data <= status_char(0); st_sending <= 1; st_start <= 1;
                end else st_timer <= st_timer + 1'b1;
            // Wait one extra clock after asserting start.  uart_tx exposes
            // busy through a registered state; without this guard the
            // index advances twice and every other character is skipped.
            end else if (!st_busy && !st_start) begin
                if (st_index == 7'd97) begin
                    st_sending <= 0;
                end else begin
                    st_index <= st_index + 1'b1;
                    st_data <= status_char(st_index + 1'b1);
                    st_start <= 1;
                end
            end
        end
    end
endmodule
