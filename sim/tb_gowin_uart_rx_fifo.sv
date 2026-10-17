`timescale 1ns/1ps
module tb_gowin_uart_rx_fifo;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg in_valid = 0;
    reg [7:0] in_data = 0;
    reg in_error = 0;
    wire in_ready;
    wire out_valid;
    reg out_ready = 0;
    wire [7:0] out_data;
    wire overflow, framing_error;
    wire [4:0] level;

    gowin_uart_rx_fifo #(.DEPTH(16), .USE_GOWIN_IP(0)) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_data(in_data), .in_error(in_error),
        .in_ready(in_ready), .out_valid(out_valid), .out_ready(out_ready),
        .out_data(out_data), .overflow(overflow),
        .framing_error(framing_error), .level(level)
    );

    task automatic push(input [7:0] value, input bit error);
        begin
            @(negedge clk);
            in_data = value; in_error = error; in_valid = 1;
            do @(posedge clk); while (!in_ready);
            @(negedge clk); in_valid = 0; in_error = 0;
        end
    endtask

    task automatic pop_expect(input [7:0] expected);
        begin
            @(negedge clk); out_ready = 1;
            do @(posedge clk); while (!out_valid);
            if (out_data !== expected)
                $fatal(1, "FIFO data mismatch: got %02x expected %02x", out_data, expected);
            @(negedge clk); out_ready = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        rst = 0;
        push(8'h55, 0);
        push(8'haa, 1);
        if (level !== 5'd2 || !framing_error)
            $fatal(1, "FIFO status mismatch level=%0d framing=%b", level, framing_error);
        pop_expect(8'h55);
        pop_expect(8'haa);
        if (level !== 5'd0 || out_valid)
            $fatal(1, "FIFO did not drain level=%0d valid=%b", level, out_valid);
        $display("tb_gowin_uart_rx_fifo PASS");
        $finish;
    end
endmodule
