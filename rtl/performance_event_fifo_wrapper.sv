module performance_event_fifo_wrapper #(
    parameter integer DEPTH = 16,
    parameter integer USE_GOWIN_FIFO = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [63:0] in_data,
    output wire        out_valid,
    input  wire        out_ready,
    output wire [63:0] out_data,
    output wire        full,
    output wire        empty,
    output reg         overflow,
    output reg         underflow,
    output wire [15:0] level
);
    // The vendor implementation is selected only after a generated FIFO_SC
    // instance has been checked for this exact device and parameter set.
    // Keeping the fallback here makes simulation and review independent of
    // encrypted Gowin simulation models.
    generate
        if (USE_GOWIN_FIFO) begin : g_vendor_fifo
            initial $error("USE_GOWIN_FIFO requires a generated FIFO_SC wrapper");
            assign in_ready = 1'b0;
            assign out_valid = 1'b0;
            assign out_data = 64'd0;
            assign full = 1'b1;
            assign empty = 1'b1;
            assign level = 16'd0;
        end else begin : g_fallback_fifo
            localparam integer PTR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
            reg [63:0] mem [0:DEPTH-1];
            reg [PTR_W-1:0] wr_ptr, rd_ptr;
            reg [PTR_W:0] count;
            wire push = in_valid && in_ready;
            wire pop = out_valid && out_ready;

            assign full = (count == DEPTH);
            assign empty = (count == 0);
            assign in_ready = !full || pop;
            assign out_valid = !empty;
            assign out_data = empty ? 64'd0 : mem[rd_ptr];
            assign level = count;

            always @(posedge clk) begin
                if (rst) begin
                    wr_ptr <= 0;
                    rd_ptr <= 0;
                    count <= 0;
                    overflow <= 1'b0;
                    underflow <= 1'b0;
                end else if (flush) begin
                    // A normal flush discards queued data but preserves the
                    // sticky diagnostics for the status registers.
                    wr_ptr <= 0;
                    rd_ptr <= 0;
                    count <= 0;
                end else begin
                    if (in_valid && !in_ready)
                        overflow <= 1'b1;
                    if (out_ready && !out_valid)
                        underflow <= 1'b1;

                    if (push) begin
                        mem[wr_ptr] <= in_data;
                        if (wr_ptr == DEPTH-1)
                            wr_ptr <= 0;
                        else
                            wr_ptr <= wr_ptr + 1'b1;
                    end
                    if (pop) begin
                        if (rd_ptr == DEPTH-1)
                            rd_ptr <= 0;
                        else
                            rd_ptr <= rd_ptr + 1'b1;
                    end
                    case ({push, pop})
                        2'b10: count <= count + 1'b1;
                        2'b01: count <= count - 1'b1;
                        default: count <= count;
                    endcase
                end
            end
        end
    endgenerate
endmodule
