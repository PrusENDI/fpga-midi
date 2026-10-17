// Mode-gated input queues.  LIVE and RECORD are independent lossless
// valid/ready paths; a modulation point is a latest-value channel because
// retaining stale expression points has no musical value.
module performance_event_ingress #(
    parameter integer DEPTH = 16,
    parameter integer USE_GOWIN_FIFO = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,
    input  wire        live_in_valid,
    output wire        live_in_ready,
    input  wire [63:0] live_in_data,
    output wire        live_out_valid,
    input  wire        live_out_ready,
    output wire [63:0] live_out_data,
    input  wire        record_in_valid,
    output wire        record_in_ready,
    input  wire [63:0] record_in_data,
    output wire        record_out_valid,
    input  wire        record_out_ready,
    output wire [63:0] record_out_data,
    input  wire        modulation_in_valid,
    output wire        modulation_in_ready,
    input  wire [63:0] modulation_in_data,
    output wire        modulation_out_valid,
    input  wire        modulation_out_ready,
    output wire [63:0] modulation_out_data,
    output wire [15:0] live_level,
    output wire [15:0] record_level,
    output wire        modulation_pending
);
    wire live_full, live_empty, live_overflow, live_underflow;
    wire record_full, record_empty, record_overflow, record_underflow;

    performance_event_fifo_wrapper #(.DEPTH(DEPTH), .USE_GOWIN_FIFO(USE_GOWIN_FIFO)) live_fifo (
        .clk(clk), .rst(!rst_n), .flush(flush),
        .in_valid(live_in_valid), .in_ready(live_in_ready), .in_data(live_in_data),
        .out_valid(live_out_valid), .out_ready(live_out_ready), .out_data(live_out_data),
        .full(live_full), .empty(live_empty), .overflow(live_overflow),
        .underflow(live_underflow), .level(live_level));

    performance_event_fifo_wrapper #(.DEPTH(DEPTH), .USE_GOWIN_FIFO(USE_GOWIN_FIFO)) record_fifo (
        .clk(clk), .rst(!rst_n), .flush(flush),
        .in_valid(record_in_valid), .in_ready(record_in_ready), .in_data(record_in_data),
        .out_valid(record_out_valid), .out_ready(record_out_ready), .out_data(record_out_data),
        .full(record_full), .empty(record_empty), .overflow(record_overflow),
        .underflow(record_underflow), .level(record_level));

    reg modulation_valid_r;
    reg [63:0] modulation_data_r;
    assign modulation_out_valid = modulation_valid_r;
    assign modulation_out_data = modulation_data_r;
    assign modulation_pending = modulation_valid_r;
    // A pending point can be replaced on the same cycle it is consumed.
    assign modulation_in_ready = !flush && (!modulation_valid_r || modulation_out_ready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            modulation_valid_r <= 1'b0;
            modulation_data_r <= 64'd0;
        end else if (flush) begin
            modulation_valid_r <= 1'b0;
            modulation_data_r <= 64'd0;
        end else begin
            if (modulation_in_valid && modulation_in_ready) begin
                modulation_valid_r <= 1'b1;
                modulation_data_r <= modulation_in_data;
            end else if (modulation_out_valid && modulation_out_ready) begin
                modulation_valid_r <= 1'b0;
            end
        end
    end
endmodule
