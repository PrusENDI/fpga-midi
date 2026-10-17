`timescale 1ns/1ps
module tb_uart_rx;
 reg clk=0;always #5 clk=~clk;reg rst=1,rx=1,ready=0;wire valid,framing_error;wire[7:0]data;
 uart_rx #(.CLK_HZ(1000),.BAUD(100)) dut(.*);
 task bit_send(input b);begin rx=b;repeat(10)@(posedge clk);end endtask
 task byte_send(input[7:0]v,input stop);integer i;begin bit_send(0);for(i=0;i<8;i=i+1)bit_send(v[i]);bit_send(stop);rx=1;repeat(3)@(posedge clk);end endtask
 initial begin repeat(3)@(posedge clk);rst=0;byte_send(8'hA5,1);if(!valid||data!==8'hA5||framing_error)$fatal(1,"valid byte");ready=1;@(posedge clk);ready=0;byte_send(8'h3C,0);if(!valid||data!==8'h3C||!framing_error)$fatal(1,"framing byte");$display("tb_uart_rx PASS");$finish;end
 initial begin #5000;$fatal(1,"timeout");end
endmodule
