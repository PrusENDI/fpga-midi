`timescale 1ns/1ps
module tb_uart_byte_serializer;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, in_valid=0, rx_ready=1;
    reg [7:0] in_data=0;
    wire in_ready, tx, busy;
    wire rx_valid, framing_error; wire [7:0] rx_data;
    uart_byte_serializer #(.CLK_HZ(1000),.BAUD(100)) dut(
        .clk(clk),.rst(rst),.in_valid(in_valid),.in_ready(in_ready),.in_data(in_data),
        .tx(tx),.busy(busy));
    uart_rx #(.CLK_HZ(1000),.BAUD(100)) loopback(
        .clk(clk),.rst(rst),.rx(tx),.valid(rx_valid),.ready(rx_ready),
        .data(rx_data),.framing_error(framing_error));
    integer got=0;
    always @(posedge clk) if(rx_valid && rx_ready) begin
        if(got==0 && rx_data!==8'hA5) $fatal(1,"first byte order");
        if(got==1 && rx_data!==8'h3C) $fatal(1,"second byte order");
        got=got+1;
    end
    task automatic send(input [7:0] value);
        begin
            @(negedge clk); in_data=value; in_valid=1;
            while(!in_ready) @(negedge clk);
            @(negedge clk); in_valid=0;
        end
    endtask
    initial begin
        repeat(3) @(posedge clk); rst=0;
        send(8'hA5); send(8'h3C);
        wait(got==2);
        if(framing_error) $fatal(1,"framing error");
        $display("tb_uart_byte_serializer PASS"); $finish;
    end
    initial begin #50000; $fatal(1,"timeout got=%0d",got); end
endmodule
