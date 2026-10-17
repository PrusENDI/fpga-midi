`timescale 1ns/1ps
module tb_uart_rx_ref;
    localparam integer BIT_CLKS = 434;
    reg clk = 0; always #10 clk = ~clk;
    reg rst = 1;
    reg rx = 1;
    wire valid;
    wire [7:0] data;
    wire framing_error;
    reg ready = 0;
    uart_rx_ref dut (.clk(clk), .rst(rst), .rx(rx), .valid(valid),
                     .ready(ready), .data(data), .framing_error(framing_error));

    task automatic bit_time(input bit value);
        begin rx = value; repeat(BIT_CLKS) @(posedge clk); end
    endtask
    task automatic send_byte(input [7:0] value);
        integer k;
        begin
            bit_time(0);
            for (k = 0; k < 8; k = k + 1) bit_time(value[k]);
            bit_time(1);
        end
    endtask
    initial begin
        repeat(4) @(posedge clk); rst = 0;
        send_byte(8'haa);
        wait(valid);
        if (data !== 8'haa || framing_error)
            $fatal(1, "reference UART RX mismatch data=%02x error=%b", data, framing_error);
        @(posedge clk); ready = 1;
        $display("tb_uart_rx_ref PASS");
        $finish;
    end
endmodule
