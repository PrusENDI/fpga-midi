`timescale 1ns/1ps
module tb_control_csr;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,req_valid=0,req_write=0,rsp_ready=0;
    reg [7:0] req_addr=0; reg [31:0] req_wdata=0;
    wire req_ready,rsp_valid; wire [7:0] rsp_status; wire [31:0] rsp_rdata;
    wire cmd_valid; reg cmd_ready=0; wire [7:0] cmd_opcode;
    wire [15:0] cmd_arg0,cmd_arg1;
    reg cmd_rsp_valid=0; wire cmd_rsp_ready;
    reg [7:0] cmd_rsp_status=1; reg [31:0] cmd_rsp_data=32'h12345678;
    control_csr dut(.*,.mode(4'd5),.selected_track(2'd2),.bpm_shadow(16'd120),
        .active_bpm(16'd90),.start_enter(16'h2000),.start_exit(16'h3000),
        .loop_tick(7'd127),.active_valid(1'b1),.commit_pending(1'b0),.fault_latched(1'b1));
    task request(input bit wr,input [7:0] address,input [31:0] data);
        @(negedge clk); req_write=wr;req_addr=address;req_wdata=data;req_valid=1;
        #1; if(!req_ready) $fatal(1,"CSR not ready");
        @(negedge clk);req_valid=0;
    endtask
    task reply(input [7:0] status,input [31:0] value);
        wait(rsp_valid); @(negedge clk);
        if(rsp_status!==status || rsp_rdata!==value) $fatal(1,"CSR response mismatch");
        repeat(3) begin @(negedge clk); if(!rsp_valid || req_ready || rsp_rdata!==value) $fatal(1,"response not held");end
        rsp_ready=1; @(negedge clk);rsp_ready=0;
    endtask
    initial begin
        repeat(2) @(negedge clk);rst_n=1;
        request(0,0,0);reply(1,5);
        request(0,8'h08,0);reply(1,{16'd90,16'd120});
        request(0,8'h30,0);reply(1,32'h30002000);
        request(1,0,123);reply(2,0);
        request(0,8'hff,0);reply(2,0);
        request(1,8'h08,32'd180);
        repeat(4) begin @(negedge clk); if(!cmd_valid || cmd_opcode!==2 || cmd_arg0!==180 || cmd_arg1!==0) $fatal(1,"atomic command not held");end
        req_wdata=77;cmd_ready=1;@(negedge clk);cmd_ready=0;
        if(cmd_valid) $fatal(1,"command repeated");
        cmd_rsp_valid=1; wait(cmd_rsp_ready); @(negedge clk);cmd_rsp_valid=0;
        reply(1,32'h12345678);
        $display("tb_control_csr PASS");$finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
