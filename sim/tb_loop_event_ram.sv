`timescale 1ns/1ps
module tb_loop_event_ram;
    reg clk = 0;
    always #10 clk = ~clk;
    GSR GSR (.GSRI(1'b1));
    reg a_en=0, a_we=0, b_en=0, b_we=0;
    reg [6:0] a_addr=0, b_addr=0;
    reg [63:0] a_wdata=0, b_wdata=0;
    wire [63:0] va, vb, ra, rb;
    loop_event_ram #(.USE_GOWIN_RAM(1)) vendor (
        .clk(clk), .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_rdata(va),
        .b_en(b_en), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata), .b_rdata(vb));
    loop_event_ram #(.USE_GOWIN_RAM(0)) reference_model (
        .clk(clk), .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata), .a_rdata(ra),
        .b_en(b_en), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata), .b_rdata(rb));
    integer i;
    reg [63:0] held_a, held_b;
    initial begin
        // Catch address aliasing, lane/byte-mask mistakes and bank crossover.
        @(negedge clk);
        for(i=0;i<64;i=i+1) begin
            a_en=1; a_we=1; a_addr=i; a_wdata=64'h0123456789ab0000+i;
            b_en=1; b_we=1; b_addr=64+i; b_wdata=64'hfedcba9876540000+i;
            @(negedge clk);
        end
        a_we=0; b_we=0;
        for(i=0;i<64;i=i+1) begin
            a_addr=64+i; b_addr=i;
            @(negedge clk);
            if (va !== 64'hfedcba9876540000+i || ra !== va)
                $fatal(1,"Port A mismatch at %0d: %h / %h",i,va,ra);
            if (vb !== 64'h0123456789ab0000+i || rb !== vb)
                $fatal(1,"Port B mismatch at %0d: %h / %h",i,vb,rb);
        end
        held_a=va; held_b=vb; a_en=0; b_en=0;
        a_addr=0; b_addr=127;
        repeat(3) @(negedge clk);
        if (va !== held_a || ra !== held_a || vb !== held_b || rb !== held_b)
            $fatal(1,"Disabled RAM ports did not hold output");
        // Playback must proceed on B while A updates a different address.
        a_en=1; a_we=1; a_addr=65; a_wdata=64'h0011aabbccddffee;
        b_en=1; b_we=0; b_addr=1;
        @(negedge clk);
        if (vb !== 64'h0123456789ab0001 || rb !== vb)
            $fatal(1,"Independent read/write failed");
        a_we=0; b_addr=65;
        @(negedge clk);
        if (vb !== 64'h0011aabbccddffee || rb !== vb)
            $fatal(1,"Written data missing on other port");
        $display("tb_loop_event_ram PASS");
        $finish;
    end
    initial begin #100000; $fatal(1,"RAM test timeout"); end
endmodule
