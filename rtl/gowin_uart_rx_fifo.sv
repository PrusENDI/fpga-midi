// Small adapter around the Gowin single-clock FIFO IP.
//
// The physical UART and the ready/valid protocol remain ordinary RTL.  Only
// the byte storage is delegated to BSRAM through the vendor FIFO.  USE=0 is
// deliberately kept as a simulation fallback so ModelSim does not need the
// encrypted Gowin implementation.
module gowin_uart_rx_fifo #(
    parameter integer DEPTH = 16,
    parameter integer USE_GOWIN_IP = 0
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       in_valid,
    input  wire [7:0] in_data,
    input  wire       in_error,
    output wire       in_ready,
    output wire       out_valid,
    input  wire       out_ready,
    output wire [7:0] out_data,
    output wire       overflow,
    output wire       framing_error,
    output wire [4:0] level
);
    generate
        if (USE_GOWIN_IP) begin : g_gowin_fifo
            wire full;
            wire empty;
            wire [7:0] q;
            wire push = in_valid && !full;
            wire pop  = out_ready && !empty;
            reg [4:0] level_reg;
            reg overflow_reg;
            reg framing_error_reg;

            gowin_uart_rx_fifo_core fifo_core (
                .Data  (in_data),
                .Clk   (clk),
                .WrEn  (push),
                .RdEn  (pop),
                .Reset (rst),
                .Q     (q),
                .Empty (empty),
                .Full  (full)
            );

            always @(posedge clk) begin
                if (rst) begin
                    level_reg        <= 5'd0;
                    overflow_reg     <= 1'b0;
                    framing_error_reg<= 1'b0;
                end else begin
                    if (in_valid && full)
                        overflow_reg <= 1'b1;
                    if (push && in_error)
                        framing_error_reg <= 1'b1;
                    case ({push, pop})
                        2'b10: level_reg <= level_reg + 1'b1;
                        2'b01: level_reg <= level_reg - 1'b1;
                        default: ;
                    endcase
                end
            end

            assign in_ready      = !full;
            assign out_valid     = !empty;
            assign out_data      = q;
            assign overflow      = overflow_reg;
            assign framing_error = framing_error_reg;
            assign level         = level_reg;
        end else begin : g_rtl_fifo
            // Reuse the verified portable implementation in simulation and
            // in non-Gowin builds.
            uart_rx_fifo #(.DEPTH(DEPTH)) rtl_fifo (
                .clk(clk), .rst(rst),
                .in_valid(in_valid), .in_data(in_data), .in_error(in_error),
                .in_ready(in_ready), .out_valid(out_valid),
                .out_ready(out_ready), .out_data(out_data),
                .overflow(overflow), .framing_error(framing_error),
                .level(level)
            );
        end
    endgenerate
endmodule
