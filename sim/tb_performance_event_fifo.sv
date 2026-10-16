`timescale 1ns/1ps

module tb_performance_event_fifo;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg flush = 1'b0;
    reg in_valid = 1'b0;
    wire in_ready;
    reg [63:0] in_data = 64'd0;
    wire out_valid;
    reg out_ready = 1'b0;
    wire [63:0] out_data;
    wire full, empty;
    wire overflow, underflow;
    wire [15:0] level;

    performance_event_fifo_wrapper #(.DEPTH(2)) dut (
        .clk(clk), .rst(rst), .flush(flush),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .full(full), .empty(empty), .overflow(overflow),
        .underflow(underflow), .level(level)
    );

    task push(input [63:0] value);
        begin
            @(negedge clk);
            in_data = value;
            in_valid = 1'b1;
            while (!in_ready) @(negedge clk);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task pop_expect(input [63:0] expected);
        begin
            @(negedge clk);
            out_ready = 1'b1;
            while (!out_valid) @(negedge clk);
            if (out_data !== expected)
                $fatal(1, "FIFO order mismatch: got %h expected %h", out_data, expected);
            @(negedge clk);
            out_ready = 1'b0;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst = 1'b0;
        push(64'h11);
        push(64'h22);
        if (!full || level != 2)
            $fatal(1, "FIFO did not fill correctly");
        in_valid = 1'b1;
        in_data = 64'h33;
        @(negedge clk);
        if (!overflow)
            $fatal(1, "overflow was not latched");
        in_valid = 1'b0;
        pop_expect(64'h11);
        pop_expect(64'h22);
        if (!empty)
            $fatal(1, "FIFO did not drain correctly");
        out_ready = 1'b1;
        @(negedge clk);
        if (!underflow)
            $fatal(1, "underflow was not latched");
        out_ready = 1'b0;
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;
        if (!empty || !overflow || !underflow)
            $fatal(1, "flush did not preserve diagnostics or clear data");
        $display("tb_performance_event_fifo PASS");
        $finish;
    end
endmodule
