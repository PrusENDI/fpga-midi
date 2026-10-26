`timescale 1ns/1ps
module tb_v2_potts_commit;
 logic clk=0,rst_n=0,start=0,ready=1,busy,done,overflow,bt,ev; logic [15:0] lam=65536; logic [127:0] rest=0; logic signed [15:0] c[0:127]; logic [7:0] prog; logic [95:0] data; logic [5:0] count; integer i,n=0; always #5 clk=~clk;
 v2_potts_commit_fsm dut(.*,.lambda_q16(lam),.rest_mask(rest),.contour(c),.progress(prog),.backtrace_valid(bt),.event_valid(ev),.event_ready(ready),.event_data(data),.event_count(count));
 initial begin for(i=0;i<128;i=i+1)c[i]=(i<64)?57:67;repeat(2)@(posedge clk);rst_n=1;@(negedge clk);start=1;@(posedge clk);#1;start=0;wait(bt);ready=0;repeat(3)@(posedge clk);ready=1;while(busy)begin @(posedge clk);if(ev&&ready)n=n+1;end;if(n<2||overflow)$fatal(1,"potts events=%0d overflow=%b",n,overflow);$display("tb_v2_potts_commit PASS events=%0d cycles=%0d",n,prog);$finish;end
endmodule
