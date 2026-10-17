`timescale 1ns/1ps
module tb_mgc3130_loop_control_path;
 reg clk=0; always #5 clk=~clk; reg rst_n=0,uart_rx=1,tx_ready=1;
 reg report_valid=0,xyz_valid=0,report_error=0,touch_valid=0; reg [15:0] x_position=0,y_position=16'h8000,z_position=16'hc000; reg [7:0] gesture_code=0; reg [31:0] touch_info=0;
 wire tx_valid; wire [7:0] tx_data; wire [3:0] mode; wire [2:0] active_voice_count; wire signed [15:0] mixed_sample; wire sample_valid; wire [1:0] selected_track; wire [6:0] loop_tick; wire active_valid,fault_latched;
 mgc3130_loop_control_path #(.CLK_HZ(100_000),.BAUD(10_000),.USE_GOWIN_RAM(0),.OP_TIMEOUT_CYCLES(200),.RX_TIMEOUT_CYCLES(3000)) dut(.*);
 task bit_in(input bit b); begin uart_rx=b; repeat(10) @(negedge clk); end endtask
 task byte_in(input [7:0] b); integer i; begin bit_in(0); for(i=0;i<8;i=i+1) bit_in(b[i]); bit_in(1); end endtask
 task command(input [7:0] op,input [7:0] seq); begin byte_in(8'h55);byte_in(8'haa);byte_in(op);byte_in(4);byte_in(1);byte_in(0);byte_in(0);byte_in(0);byte_in(seq);byte_in(op^8'd4^8'd1^seq); end endtask
 reg [7:0] response[0:9]; integer ri=0,rc=0,i; always @(posedge clk) if(rst_n&&tx_valid&&tx_ready) begin response[ri]<=tx_data;if(ri==9)begin ri=0;rc=rc+1;end else ri=ri+1;end
 task sensor; begin @(negedge clk);report_valid=1;xyz_valid=1;@(negedge clk);report_valid=0;xyz_valid=0;end endtask
 initial begin repeat(4)@(negedge clk);rst_n=1; command(1,1); wait(rc==1); if(mode!==1||response[3]!==1)$fatal(1,"SET_MODE failed mode=%0d rc=%0d",mode,rc); command(0,2); wait(rc==2); if(response[3]!==1||{response[7],response[6],response[5],response[4]}!==1)$fatal(1,"STATUS failed"); for(i=0;i<7;i=i+1)sensor; repeat(40)@(negedge clk); if(active_voice_count==0)$fatal(1,"sensor event not mixed"); $display("tb_mgc3130_loop_control_path PASS");$finish;end
 initial begin #100_000_000;$fatal(1,"timeout mode=%0d responses=%0d",mode,rc);end
endmodule
