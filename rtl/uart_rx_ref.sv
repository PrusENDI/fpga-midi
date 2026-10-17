// UART receiver adapted from the board vendor's working Tang Primer example.
// It keeps the same byte-level ready/valid interface as uart_rx, while using
// the reference state machine and sampling points that are already proven on
// the B3 USB-UART input.
module uart_rx_ref #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg        valid,
    input  wire       ready,
    output reg [7:0]  data,
    output reg        framing_error
);
    localparam integer CYCLE = CLK_HZ / BAUD;
    localparam integer HALF_CYCLE = CYCLE / 2;
    localparam [15:0] CYCLE_M1 = CYCLE - 1;
    localparam [15:0] HALF_M1 = HALF_CYCLE - 1;
    localparam [2:0] S_IDLE = 3'd1, S_START = 3'd2, S_REC_BYTE = 3'd3,
                     S_STOP = 3'd4, S_DATA = 3'd5;

    reg [2:0] state, next_state;
    reg rx_d0, rx_d1;
    wire rx_negedge = rx_d1 && !rx_d0;
    reg [7:0] rx_bits;
    reg [15:0] cycle_cnt;
    reg [2:0] bit_cnt;

    always @* begin
        case (state)
            S_IDLE:     next_state = rx_negedge ? S_START : S_IDLE;
            S_START:    next_state = (cycle_cnt == CYCLE_M1) ? S_REC_BYTE : S_START;
            S_REC_BYTE: next_state = (cycle_cnt == CYCLE_M1 && bit_cnt == 3'd7) ? S_STOP : S_REC_BYTE;
            S_STOP:     next_state = (cycle_cnt == HALF_M1) ? S_DATA : S_STOP;
            S_DATA:     next_state = ready ? S_IDLE : S_DATA;
            default:    next_state = S_IDLE;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_d0 <= 1'b1;
            rx_d1 <= 1'b1;
            state <= S_IDLE;
            valid <= 1'b0;
            data <= 8'h00;
            framing_error <= 1'b0;
            rx_bits <= 8'h00;
            cycle_cnt <= 16'd0;
            bit_cnt <= 3'd0;
        end else begin
            rx_d0 <= rx;
            rx_d1 <= rx_d0;
            state <= next_state;

            if (state == S_STOP && next_state != state) begin
                valid <= 1'b1;
                data <= rx_bits;
                // The reference implementation does not reject a byte on
                // stop-bit errors. Preserve the diagnostic output without
                // changing its byte acceptance behavior.
                framing_error <= !rx_d0;
            end else if (state == S_DATA && ready) begin
                valid <= 1'b0;
                framing_error <= 1'b0;
            end

            if ((state == S_REC_BYTE && cycle_cnt == CYCLE_M1) || next_state != state)
                cycle_cnt <= 16'd0;
            else
                cycle_cnt <= cycle_cnt + 16'd1;

            if (state == S_REC_BYTE && cycle_cnt == CYCLE_M1)
                bit_cnt <= bit_cnt + 3'd1;
            else if (state != S_REC_BYTE)
                bit_cnt <= 3'd0;

            if (state == S_REC_BYTE && cycle_cnt == HALF_M1)
                rx_bits[bit_cnt] <= rx;
        end
    end
endmodule
