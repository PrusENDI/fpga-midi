`timescale 1ns/1ps
module tb_mgc3130_loop_control_path;
 reg clk=0; always #5 clk=~clk; reg rst_n=0,uart_rx=1,tx_ready=1;
 reg report_valid=0,xyz_valid=0,report_error=0,touch_valid=0; reg [15:0] x_position=16'h1000,y_position=16'h8000,z_position=16'h4800; reg [7:0] gesture_code=0; reg [31:0] touch_info=0;
 wire tx_valid; wire [7:0] tx_data; wire [3:0] mode; wire [2:0] active_voice_count; wire signed [15:0] mixed_sample; wire sample_valid; wire [1:0] selected_track; wire [6:0] loop_tick; wire active_valid,fault_latched; wire rx_overflow,rx_framing_error,adapter_overflow; wire [15:0] report_count,xyz_count;
 mgc3130_loop_control_path #(.CLK_HZ(100_000),.BAUD(10_000),.USE_GOWIN_RAM(0),.OP_TIMEOUT_CYCLES(200),.RX_TIMEOUT_CYCLES(3000)) dut(.*);
 task bit_in(input bit b); begin uart_rx=b; repeat(10) @(negedge clk); end endtask
 task byte_in(input [7:0] b); integer i; begin bit_in(0); for(i=0;i<8;i=i+1) bit_in(b[i]); bit_in(1); end endtask
 task command(input [7:0] op,input [7:0] seq); begin byte_in(8'h55);byte_in(8'haa);byte_in(op);byte_in(4);byte_in(1);byte_in(0);byte_in(0);byte_in(0);byte_in(seq);byte_in(op^8'd4^8'd1^seq); end endtask
 task command_zero(input [7:0] op,input [7:0] seq); begin byte_in(8'h55);byte_in(8'haa);byte_in(op);byte_in(4);byte_in(0);byte_in(0);byte_in(0);byte_in(0);byte_in(seq);byte_in(op^8'd4^seq); end endtask
 reg [7:0] response[0:39]; integer ri=0,rc=0,i; always @(posedge clk) if(rst_n&&tx_valid&&tx_ready) begin response[rc*10+ri]<=tx_data;if(ri==9)begin ri=0;rc=rc+1;end else ri=ri+1;end
 task sensor; begin @(negedge clk);report_valid=1;xyz_valid=1;@(negedge clk);report_valid=0;xyz_valid=0;end endtask
 initial begin repeat(4)@(negedge clk);rst_n=1; command(1,1); wait(rc==2); if(mode!==1||response[3]!==0||response[13]!==1)$fatal(1,"SET_MODE failed mode=%0d rc=%0d",mode,rc); command(0,2); wait(rc==4); if(response[33]!==1||{response[37],response[36],response[35],response[34]}!==1) begin $display("STATUS applied bytes=%02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",response[30],response[31],response[32],response[33],response[34],response[35],response[36],response[37],response[38],response[39]); $fatal(1,"STATUS failed"); end; for(i=0;i<7;i=i+1)sensor; repeat(40)@(negedge clk); if(active_voice_count==0)$fatal(1,"sensor event not mixed");
   // LIVE must derive pitch from the complete X range while Y is held still.
   force dut.live_mapper.event_ready=1'b0;
   x_position=16'hefff; y_position=16'h8000; z_position=16'h4800;
   for(i=0;i<7;i=i+1)sensor;
   if(!dut.live_mapper.event_valid || dut.live_mapper.event_data[25:19]!==7'd72)$fatal(1,"LIVE pitch is not mapped from X");
   release dut.live_mapper.event_ready;
   // Regression: a pending adapter event must be cancelled by STOP.  Hold
   // its downstream ready low so the event is guaranteed to remain pending.
   force dut.live_mapper.event_ready=1'b0;
   z_position=16'h4800;
   for(i=0;i<7;i=i+1)sensor;
   if(!dut.live_mapper.event_valid)$fatal(1,"failed to create pending live event");
   command_zero(5,3);
   wait(dut.audio_path.control.manager.flush_events===1'b1);
   if(dut.adapter.flush!==1'b1)$fatal(1,"STOP flush did not reach input adapter");
   release dut.live_mapper.event_ready;
   $display("tb_mgc3130_loop_control_path PASS");$finish;end
 initial begin #100_000_000;$fatal(1,"timeout mode=%0d responses=%0d",mode,rc);end
endmodule
