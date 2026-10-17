`timescale 1ns/1ps
module tb_uart_rx_fifo;
 reg clk=0;always #5 clk=~clk;reg rst=1,in_valid=0,in_error=0,out_ready=0;reg[7:0]in_data=0;wire in_ready,out_valid,overflow,framing_error;wire[7:0]out_data;wire[4:0]level;
 uart_rx_fifo #(.DEPTH(2)) dut(.*);
 initial begin repeat(2)@(posedge clk);rst=0;in_valid=1;in_data=8'h11;@(posedge clk);in_data=8'h22;@(posedge clk);in_data=8'h33;@(posedge clk);#1;if(!overflow||in_ready)$fatal(1,"fifo overflow");in_valid=0;out_ready=1;#1;if(out_data!==8'h11)$fatal(1,"fifo order1");@(posedge clk);#1;if(out_data!==8'h22)$fatal(1,"fifo order2");@(posedge clk);in_valid=1;in_error=1;in_data=8'h44;@(posedge clk);#1;if(!framing_error)$fatal(1,"sticky framing");$display("tb_uart_rx_fifo PASS");$finish;end
 initial begin #1000;$fatal(1,"timeout");end
endmodule
