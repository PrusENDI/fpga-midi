`timescale 1ns/1ps
module tb_performance_event_voice_bridge;
 import performance_event_pkg::*; reg clk=0;always #5 clk=~clk;reg rst_n=0,valid=0;reg[63:0] data;
 wire ready,note_on,note_off,expression_valid;wire[6:0] note_number;wire[7:0] velocity;
 performance_event_voice_bridge dut(.*,.event_valid(valid),.event_ready(ready),.event_data(data));
 initial begin repeat(2)@(posedge clk);rst_n=1;data=64'd0;data[2:0]=EVENT_NOTE_ON;data[25:19]=7'd60;data[33:26]=8'd90;valid=1;@(posedge clk);#1;if(!note_on||note_number!=60||velocity!=90)$fatal(1,"note on");valid=0;@(posedge clk);#1;if(note_on)$fatal(1,"pulse");data[2:0]=EVENT_ALL_NOTES_OFF;valid=1;@(posedge clk);#1;if(!note_off)$fatal(1,"all off");$display("tb_performance_event_voice_bridge PASS");$finish;end
 initial begin #1000;$fatal(1,"timeout");end
endmodule
