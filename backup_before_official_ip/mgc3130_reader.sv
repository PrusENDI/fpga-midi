module mgc3130_reader #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 100_000,
    parameter [6:0] I2C_ADDR = 7'h42
) (
    input  wire        clk,
    input  wire        rst_n,

    inout  wire         i2c_sda,
    inout  wire         i2c_scl,
    inout  wire         mgc_ts,

    output reg        report_valid,
    output reg        xyz_valid,
    output reg [15:0] x_position,
    output reg [15:0] y_position,
    output reg [15:0] z_position,
    output reg [7:0]  gesture_code,
    output reg        report_error,
    output reg [3:0]  error_code,
    output reg        busy
);

    localparam integer HALF_TICKS = CLK_HZ / (I2C_HZ * 2);
    localparam integer HALF_W = (HALF_TICKS <= 1) ? 1 : $clog2(HALF_TICKS + 1);

    reg sda_oe, sda_out;
    reg scl_oe, scl_out;
    reg ts_oe;
    reg [HALF_W-1:0] tick_count;

    assign i2c_sda = sda_oe ? sda_out : 1'bz;
    assign i2c_scl = scl_oe ? scl_out : 1'bz;
    assign mgc_ts  = ts_oe  ? 1'b0   : 1'bz;

    wire sda_in;
    wire scl_in;
    wire ts_in;
    assign sda_in = i2c_sda;
    assign scl_in = i2c_scl;
    assign ts_in  = mgc_ts;

    localparam [5:0] ST_WAIT_TS=6'd0, ST_START_A=6'd1, ST_START_B=6'd2, ST_SEND_ADDR_SET=6'd3, ST_SEND_ADDR_HIGH=6'd4, ST_SEND_ADDR_LOW=6'd5, ST_ADDR_ACK_SET=6'd6, ST_ADDR_ACK_HIGH=6'd7, ST_ADDR_ACK_LOW=6'd8, ST_READ_SET=6'd9, ST_READ_HIGH=6'd10, ST_READ_LOW=6'd11, ST_READ_ACK_SET=6'd12, ST_READ_ACK_HIGH=6'd13, ST_READ_ACK_LOW=6'd14, ST_STOP_A=6'd15, ST_STOP_B=6'd16, ST_STOP_C=6'd17, ST_FINISH=6'd18, ST_ERROR=6'd19;
    reg [5:0] state;
    localparam [5:0] ST_START_HOLD = 6'd20;
    localparam [5:0] ST_ADDR_SETUP_HOLD = 6'd21;
    reg [7:0] frame [0:23];
    reg [7:0] tx_byte;
    reg [4:0] tx_bit;
    reg [4:0] rx_byte;
    reg [3:0] rx_bit;
    reg       last_byte;
    reg [15:0] stretch_count;

    function tick_done;
        input [HALF_W-1:0] tick_arg;
        begin tick_done = (tick_arg == HALF_TICKS-1); end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_WAIT_TS;
            sda_oe        <= 1'b0;
            sda_out       <= 1'b1;
            scl_oe        <= 1'b0;
            scl_out       <= 1'b1;
            ts_oe         <= 1'b0;
            tick_count    <= 0;
            stretch_count <= 0;
            tx_byte       <= 0;
            tx_bit        <= 0;
            rx_byte       <= 0;
            rx_bit        <= 0;
            last_byte     <= 1'b0;
            report_valid  <= 1'b0;
            xyz_valid     <= 1'b0;
            report_error  <= 1'b0;
            error_code    <= 4'd0;
            x_position    <= 0;
            y_position    <= 0;
            z_position    <= 0;
            gesture_code  <= 0;
            busy          <= 1'b0;
        end else begin
            report_valid <= 1'b0;
            report_error <= 1'b0;

            if (!tick_done(tick_count)) begin
                tick_count <= tick_count + 1'b1;
            end

            case (state)
                ST_WAIT_TS: begin
                    busy      <= 1'b0;
                    ts_oe     <= 1'b0;
                    sda_oe    <= 1'b0;
                    scl_oe    <= 1'b0;
                    tick_count <= 0;
                    if (ts_in == 1'b0) begin
                        busy       <= 1'b1;
                        ts_oe      <= 1'b1;
                        // SDA is open-drain. Leave it released while the
                        // bus is idle; actively driving a logic-one here
                        // corrupts the START/address phase.
                        sda_oe     <= 1'b0;
                        sda_out    <= 1'b0;
                        scl_oe     <= 1'b0;
                        tx_byte    <= {I2C_ADDR, 1'b1};
                        tx_bit     <= 5'd7;
                        rx_byte    <= 5'd0;
                        rx_bit     <= 4'd7;
                        last_byte  <= 1'b0;
                        state      <= ST_START_A;
                    end
                end

                // Bus idle: SDA and SCL high, then SDA falls while SCL is high.
                ST_START_A: if (tick_done(tick_count)) begin
                    // Open-drain bus: release SDA for a logic 1.
                    sda_oe     <= 1'b0;
                    sda_out    <= 1'b0;
                    scl_oe     <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_START_B;
                end

                ST_START_B: if (tick_done(tick_count)) begin
                    sda_oe     <= 1'b1;
                    sda_out    <= 1'b0;
                    // START: SDA falls while SCL stays high. Keep this
                    // condition for a full half-period before lowering SCL.
                    scl_oe     <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_START_HOLD;
                end

                ST_START_HOLD: if (tick_done(tick_count)) begin
                    scl_oe     <= 1'b1;
                    scl_out    <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_SEND_ADDR_SET;
                end

                ST_SEND_ADDR_SET: if (tick_done(tick_count)) begin
                    // SDA is open-drain: drive only zero, release for one.
                    sda_oe     <= (tx_byte[tx_bit] == 1'b0);
                    sda_out    <= 1'b0;
                    scl_oe     <= 1'b1;
                    scl_out    <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_ADDR_SETUP_HOLD;
                end

                // Allow SDA to settle (including external pull-up rise)
                // before releasing SCL to clock the address bit.
                ST_ADDR_SETUP_HOLD: if (tick_done(tick_count)) begin
                    tick_count <= 0;
                    state      <= ST_SEND_ADDR_HIGH;
                end

                ST_SEND_ADDR_HIGH: begin
                    scl_oe <= 1'b0; // release SCL; wait for stretching to end
                    if (scl_in) begin
                        if (tick_done(tick_count)) begin
                            tick_count <= 0;
                            state <= ST_SEND_ADDR_LOW;
                        end
                    end else begin
                        if (stretch_count == 16'hFFFF) begin error_code <= 4'd2; state <= ST_ERROR; end
                        else stretch_count <= stretch_count + 1'b1;
                    end
                end

                ST_SEND_ADDR_LOW: if (tick_done(tick_count)) begin
                    scl_oe        <= 1'b1;
                    scl_out       <= 1'b0;
                    tick_count    <= 0;
                    stretch_count <= 0;
                    if (tx_bit == 0) state <= ST_ADDR_ACK_SET;
                    else begin
                        tx_bit <= tx_bit - 1'b1;
                        state  <= ST_SEND_ADDR_SET;
                    end
                end

                ST_ADDR_ACK_SET: if (tick_done(tick_count)) begin
                    sda_oe     <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_ADDR_ACK_HIGH;
                end

                ST_ADDR_ACK_HIGH: begin
                    scl_oe <= 1'b0;
                    if (scl_in) begin
                        if (tick_done(tick_count)) begin
                            tick_count <= 0;
                            if (sda_in) begin error_code <= 4'd1; state <= ST_ERROR; end
                            else state <= ST_ADDR_ACK_LOW;
                        end
                    end else if (stretch_count != 16'hFFFF) begin
                        stretch_count <= stretch_count + 1'b1;
                    end else begin error_code <= 4'd3; state <= ST_ERROR; end
                end

                ST_ADDR_ACK_LOW: if (tick_done(tick_count)) begin
                    scl_oe     <= 1'b1;
                    scl_out    <= 1'b0;
                    rx_byte    <= 5'd0;
                    rx_bit     <= 4'd7;
                    tick_count <= 0;
                    state      <= ST_READ_SET;
                end

                ST_READ_SET: if (tick_done(tick_count)) begin
                    sda_oe     <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_READ_HIGH;
                end

                ST_READ_HIGH: begin
                    scl_oe <= 1'b0;
                    if (scl_in) begin
                        if (tick_done(tick_count)) begin
                            frame[rx_byte][rx_bit] <= sda_in;
                            tick_count <= 0;
                            state <= ST_READ_LOW;
                        end
                    end else if (stretch_count != 16'hFFFF) begin
                        stretch_count <= stretch_count + 1'b1;
                    end else begin error_code <= 4'd4; state <= ST_ERROR; end
                end

                ST_READ_LOW: if (tick_done(tick_count)) begin
                    scl_oe        <= 1'b1;
                    scl_out       <= 1'b0;
                    stretch_count <= 0;
                    tick_count    <= 0;
                    if (rx_bit == 0) begin
                        last_byte <= (rx_byte == 23);
                        state <= ST_READ_ACK_SET;
                    end else begin
                        rx_bit <= rx_bit - 1'b1;
                        state  <= ST_READ_SET;
                    end
                end

                ST_READ_ACK_SET: begin
                    // ACK every byte except the final byte, which is NACK.
                    // NACK is represented by releasing SDA; never drive a
                    // logic-one onto the open-drain bus.
                    sda_oe     <= last_byte ? 1'b0 : 1'b1;
                    sda_out    <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_READ_ACK_HIGH;
                end

                ST_READ_ACK_HIGH: begin
                    scl_oe <= 1'b0;
                    if (scl_in) begin
                        if (tick_done(tick_count)) begin
                            tick_count <= 0;
                            state <= ST_READ_ACK_LOW;
                        end
                    end else if (stretch_count != 16'hFFFF) begin
                        stretch_count <= stretch_count + 1'b1;
                    end else begin error_code <= 4'd5; state <= ST_ERROR; end
                end

                ST_READ_ACK_LOW: if (tick_done(tick_count)) begin
                    scl_oe     <= 1'b1;
                    scl_out    <= 1'b0;
                    sda_oe     <= 1'b0;
                    tick_count <= 0;
                    if (last_byte) state <= ST_STOP_A;
                    else begin
                        rx_byte <= rx_byte + 1'b1;
                        rx_bit  <= 4'd7;
                        state   <= ST_READ_SET;
                    end
                end

                ST_STOP_A: if (tick_done(tick_count)) begin
                    sda_oe     <= 1'b1;
                    sda_out    <= 1'b0;
                    scl_oe     <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_STOP_B;
                end

                ST_STOP_B: begin
                    if (scl_in) begin
                        if (tick_done(tick_count)) begin
                            tick_count <= 0;
                            state <= ST_STOP_C;
                        end
                    end else if (stretch_count != 16'hFFFF) begin
                        stretch_count <= stretch_count + 1'b1;
                    end else begin error_code <= 4'd6; state <= ST_ERROR; end
                end

                ST_STOP_C: if (tick_done(tick_count)) begin
                    sda_oe     <= 1'b0;
                    ts_oe      <= 1'b0;
                    tick_count <= 0;
                    state      <= ST_FINISH;
                end

                ST_FINISH: begin
                    busy         <= 1'b0;
                    report_valid <= 1'b1;
                    if ((frame[3] == 8'h91) && (frame[4] == 8'h1E)) begin
                        xyz_valid    <= frame[7][0];
                        gesture_code <= frame[8];
                        x_position   <= {frame[19], frame[18]};
                        y_position   <= {frame[21], frame[20]};
                        z_position   <= {frame[23], frame[22]};
                    end else begin
                        error_code  <= 4'd7;
                        report_error <= 1'b1;
                    end
                    state <= ST_WAIT_TS;
                end

                ST_ERROR: begin
                    busy         <= 1'b0;
                    // Emit an error report so the UART is not silent when
                    // TS was asserted but the I2C transaction failed.
                    report_valid <= 1'b1;
                    report_error <= 1'b1;
                    sda_oe       <= 1'b0;
                    scl_oe       <= 1'b0;
                    ts_oe        <= 1'b0;
                    tick_count   <= 0;
                    state        <= ST_WAIT_TS;
                end

                default: state <= ST_WAIT_TS;
            endcase
        end
    end
endmodule
