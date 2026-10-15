module mgc3130_uart_top (
    input  wire clk_50m,
    inout  wire mgc_sda,
    inout  wire mgc_scl,
    inout  wire mgc_ts,
    inout  wire mgc_mclr,
    output wire uart_tx
);
    wire mgc_mclr_drive_low;
    wire mgc_ready;
    assign mgc_mclr = mgc_mclr_drive_low ? 1'b0 : 1'bz;

    mgc3130_reset_seq #(.CLK_HZ(50_000_000), .RESET_LOW_MS(250), .STARTUP_WAIT_MS(2000)) u_reset_seq (
        .clk(clk_50m), .mclr_drive_low(mgc_mclr_drive_low), .ready(mgc_ready)
    );

    wire        report_valid;
    wire        xyz_valid;
    wire [15:0] x_position;
    wire [15:0] y_position;
    wire [15:0] z_position;
    wire [7:0]  gesture_code;
    wire        report_error;
    wire [3:0]  error_code;
    wire        reader_busy;

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
        .x_position   (x_position),
        .y_position   (y_position),
        .z_position   (z_position),
        .gesture_code (gesture_code),
        .report_error (report_error),
        .error_code   (error_code),
        .busy         (reader_busy)
    );

    // Diagnostic UART: print physical line levels once per second.
    // This deliberately replaces the binary report transmitter while the
    // I2C link is being diagnosed.
    localparam integer STATUS_PERIOD = 50_000_000;
    reg [31:0] st_timer;
    reg [4:0] st_index;
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
        input [4:0] n;
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
                30: status_char = 8'h0d; default: status_char = 8'h0a;
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
        .data(st_data), .tx(uart_tx), .busy(st_busy)
    );

    always @(posedge clk_50m or negedge mgc_ready) begin
        if (!mgc_ready) begin
            st_timer <= 0; st_index <= 0; st_sending <= 0;
            st_start <= 0; st_data <= 0;
            st_ts_latched <= 1'b1; st_mclr_latched <= 1'b0;
            st_sda_latched <= 1'b1; st_scl_latched <= 1'b1;
            valid_count <= 0; error_count <= 0;
            valid_latched <= 0; error_latched <= 0;
            code_latched <= 0;
        end else begin
            if (report_valid) valid_count <= valid_count + 1'b1;
            if (report_error) error_count <= error_count + 1'b1;
            st_start <= 0;
            if (!st_sending) begin
                if (st_timer == STATUS_PERIOD - 1) begin
                    st_timer <= 0; st_index <= 0;
                    st_ts_latched <= ts_level;
                    st_mclr_latched <= mclr_level;
                    st_sda_latched <= sda_level;
                    st_scl_latched <= scl_level;
                    valid_latched <= valid_count;
                    error_latched <= error_count;
                    code_latched <= error_code;
                    st_data <= status_char(0); st_sending <= 1; st_start <= 1;
                end else st_timer <= st_timer + 1'b1;
            // Wait one extra clock after asserting start.  uart_tx exposes
            // busy through a registered state; without this guard the
            // index advances twice and every other character is skipped.
            end else if (!st_busy && !st_start) begin
                if (st_index == 5'd31) begin
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
