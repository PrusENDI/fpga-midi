// Board-facing Loop path. It owns the physical command RX FIFO, converts a
// latched MGC3130 report into Loop events, and exposes mailbox bytes before
// they are serialized by the board's existing UART TX timing.
module mgc3130_loop_control_path #(
    parameter integer CLK_HZ=50_000_000,
    parameter integer BAUD=115_200,
    parameter integer USE_GOWIN_RAM=1,
    parameter integer USE_GOWIN_FIFO=0,
    parameter integer USE_REF_UART_RX=0,
    parameter integer OP_TIMEOUT_CYCLES=CLK_HZ,
    parameter integer BOUNDARY_TIMEOUT_CYCLES=1_700_000_000,
    parameter integer RX_TIMEOUT_CYCLES=500000
) (
    input wire clk, input wire rst_n, input wire uart_rx,
    output wire tx_valid, input wire tx_ready, output wire [7:0] tx_data,
    input wire report_valid, input wire xyz_valid, input wire report_error,
    input wire touch_valid, input wire [31:0] touch_info,
    input wire [15:0] x_position, y_position, z_position,
    input wire [7:0] gesture_code,
    output wire [3:0] mode, output wire [1:0] selected_track,
    output wire [6:0] loop_tick, output wire active_valid,
    output wire fault_latched,
    output wire rx_overflow, output wire rx_framing_error,
    output wire adapter_overflow,
    output wire signed [15:0] mixed_sample, output wire sample_valid,
    output wire [2:0] active_voice_count,
    output reg [15:0] report_count, output reg [15:0] xyz_count
);
    wire rx_valid, rx_ready;
    wire [7:0] rx_data;
    wire rx_overflow_i, rx_framing_error_i;
    wire adapter_overflow_i;
    uart_control_link #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.FIFO_DEPTH(16),.USE_GOWIN_FIFO(USE_GOWIN_FIFO),.USE_REF_UART_RX(USE_REF_UART_RX)) command_rx (
        .clk(clk), .rst(!rst_n), .rx(uart_rx), .rx_valid(rx_valid),
        .rx_ready(rx_ready), .rx_data(rx_data), .overflow(rx_overflow_i),
        .framing_error(rx_framing_error_i)
    );

    wire latched_input_valid, latched_xyz_valid, latched_report_valid;
    wire latched_report_error, latched_touch_valid;
    wire [15:0] latched_x, latched_y, latched_z;
    wire [7:0] latched_gesture;
    wire [31:0] latched_touch_info;
    mgc3130_input_latch input_latch (
        .clk(clk), .rst_n(rst_n), .report_valid(report_valid),
        .xyz_valid(xyz_valid), .report_error(report_error),
        .x_position(x_position), .y_position(y_position), .z_position(z_position),
        .gesture_code(gesture_code), .input_valid(latched_input_valid),
        .xyz_valid_latched(latched_xyz_valid), .x_latched(latched_x),
        .y_latched(latched_y), .z_latched(latched_z),
        .gesture_latched(latched_gesture), .touch_info(touch_info),
        .touch_valid(touch_valid), .report_valid_latched(latched_report_valid),
        .report_error_latched(latched_report_error),
        .touch_valid_latched(latched_touch_valid),
        .touch_info_latched(latched_touch_info)
    );

    wire [15:0] start_enter, start_exit;
    wire live_valid, path_live_ready; wire [63:0] live_data;
    wire record_valid, record_ready; wire [63:0] record_data;
    wire modulation_valid, path_modulation_ready; wire [63:0] modulation_data;
    wire record_start, record_start_ready, adapter_idle;
    wire adapter_live_valid, adapter_live_ready; wire [63:0] adapter_live_data;
    wire adapter_modulation_valid, adapter_modulation_ready; wire [63:0] adapter_modulation_data;
    wire adapter_idle_i;
    wire mapper_event_valid, mapper_event_ready; wire [63:0] mapper_event_data;
    wire mapper_modulation_valid, mapper_modulation_ready; wire [63:0] mapper_modulation_data;
    wire mapper_idle, mapper_overflow;
    wire adapter_flush;
    // The loop control plane accepts the one-cycle record-start handshake
    // whenever the adapter is armed; there is no downstream backpressure
    // signal at this boundary.
    assign record_start_ready = 1'b1;
    input_event_adapter adapter (
        .clk(clk), .rst_n(rst_n), .report_valid(latched_report_valid),
        .xyz_valid(latched_xyz_valid), .report_error(latched_report_error),
        .x_position(latched_x), .y_position(latched_y), .z_position(latched_z),
        .touch_valid(latched_touch_valid), .touch_info(latched_touch_info),
        .presence_valid(1'b0), .present(1'b1), .mode(mode == 4'd1 ? 4'd0 : mode),
        .selected_track(selected_track), .loop_tick(loop_tick),
        .start_enter(start_enter), .start_exit(start_exit), .flush(adapter_flush),
        .live_valid(adapter_live_valid), .live_ready(adapter_live_ready), .live_event(adapter_live_data),
        .record_valid(record_valid), .record_ready(record_ready), .record_event(record_data),
        .modulation_valid(adapter_modulation_valid), .modulation_ready(adapter_modulation_ready),
        .modulation_event(adapter_modulation_data), .record_start(record_start),
        .record_start_ready(record_start_ready), .idle(adapter_idle_i),
        .overflow(adapter_overflow_i)
    );

    live_xyz_mapper live_mapper (
        .clk(clk), .rst_n(rst_n), .enable(mode == 4'd1), .flush(adapter_flush),
        .report_valid(latched_report_valid), .xyz_valid(latched_xyz_valid),
        .report_error(latched_report_error), .x_position(latched_x),
        .y_position(latched_y), .z_position(latched_z),
        .selected_track(selected_track), .event_valid(mapper_event_valid),
        .event_ready(mapper_event_ready), .event_data(mapper_event_data),
        .modulation_valid(mapper_modulation_valid), .modulation_ready(mapper_modulation_ready),
        .modulation_data(mapper_modulation_data), .idle(mapper_idle), .overflow(mapper_overflow));

    assign live_valid = (mode == 4'd1) ? mapper_event_valid : adapter_live_valid;
    assign live_data = (mode == 4'd1) ? mapper_event_data : adapter_live_data;
    assign mapper_event_ready = (mode == 4'd1) ? path_live_ready : 1'b0;
    assign adapter_live_ready = (mode == 4'd1) ? 1'b1 : path_live_ready;
    assign modulation_valid = (mode == 4'd1) ? mapper_modulation_valid : adapter_modulation_valid;
    assign modulation_data = (mode == 4'd1) ? mapper_modulation_data : adapter_modulation_data;
    assign mapper_modulation_ready = (mode == 4'd1) ? path_modulation_ready : 1'b0;
    assign adapter_modulation_ready = (mode == 4'd1) ? 1'b1 : path_modulation_ready;
    assign adapter_idle = (mode == 4'd1) ? mapper_idle : adapter_idle_i;

    loop_audio_path #(.CLK_HZ(CLK_HZ),.USE_GOWIN_RAM(USE_GOWIN_RAM),
        .OP_TIMEOUT_CYCLES(OP_TIMEOUT_CYCLES),
        .BOUNDARY_TIMEOUT_CYCLES(BOUNDARY_TIMEOUT_CYCLES),
        .RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)) audio_path (
        .clk(clk), .rst_n(rst_n), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .rx_data(rx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .tx_data(tx_data), .record_start(record_start),
        .live_valid(live_valid), .live_ready(path_live_ready), .live_data(live_data),
        .record_valid(record_valid), .record_ready(record_ready), .record_data(record_data),
        .modulation_valid(modulation_valid), .modulation_ready(path_modulation_ready),
        .modulation_data(modulation_data), .adapter_idle(adapter_idle),
        .flush_events(adapter_flush),
        .mixed_sample(mixed_sample), .sample_valid(sample_valid),
        .active_voice_count(active_voice_count), .mode(mode),
        .selected_track(selected_track), .start_enter(start_enter),
        .start_exit(start_exit), .loop_tick(loop_tick),
        .active_valid(active_valid), .fault_latched(fault_latched),
        .adapter_overflow(adapter_overflow_i | mapper_overflow),
        .report_count(report_count), .xyz_count(xyz_count)
    );
    // Keep diagnostic output ports as explicit single-driver nets.  The Gowin
    // synthesizer is stricter than simulation when a child output is connected
    // directly to a parent output port.
    assign rx_overflow = rx_overflow_i;
    assign rx_framing_error = rx_framing_error_i;
    assign adapter_overflow = adapter_overflow_i | mapper_overflow;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            report_count <= 16'd0;
            xyz_count <= 16'd0;
        end else begin
            if (report_valid && report_count != 16'hffff)
                report_count <= report_count + 1'b1;
            if (report_valid && xyz_valid && !report_error && xyz_count != 16'hffff)
                xyz_count <= xyz_count + 1'b1;
        end
    end
endmodule
