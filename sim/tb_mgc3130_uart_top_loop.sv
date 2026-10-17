`timescale 1ns/1ps
module tb_mgc3130_uart_top_loop;
    reg clk=0; always #10 clk=~clk;
    GSR GSR(.GSRI(1'b1));
    tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
    pullup(mgc_sda); pullup(mgc_scl); pullup(mgc_ts); pullup(mgc_mclr);
    reg uart_rx=1;
    wire uart_tx, bck, lrck, din;
    mgc3130_uart_top #(
        .AUDIO_STREAM(0), .AUDIO_OUTPUT(0), .LOOP_CONTROL_ENABLE(1),
        .RESET_LOW_MS(1), .STARTUP_WAIT_MS(1)
    ) dut (
        .clk_50m(clk), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl),
        .mgc_ts(mgc_ts), .mgc_mclr(mgc_mclr), .uart_tx(uart_tx),
        .uart_rx(uart_rx), .pcm5102a_bck(bck), .pcm5102a_lrck(lrck),
        .pcm5102a_din(din)
    );

    localparam integer BIT_CLKS=434;
    task automatic uart_bit(input bit value);
        begin uart_rx=value; repeat(BIT_CLKS) @(posedge clk); end
    endtask
    task automatic uart_byte(input [7:0] value);
        integer k;
        begin uart_bit(0); for(k=0;k<8;k=k+1) uart_bit(value[k]); uart_bit(1); end
    endtask
    task automatic command(input [7:0] opcode,input [7:0] sequence_id);
        begin
            uart_byte(8'h55); uart_byte(8'haa); uart_byte(opcode); uart_byte(8'd4);
            uart_byte(8'd1); uart_byte(8'd0); uart_byte(8'd0); uart_byte(8'd0);
            uart_byte(sequence_id); uart_byte(opcode ^ 8'd4 ^ 8'd1 ^ sequence_id);
        end
    endtask

    integer rx_count=0, frame_count=0, i;
    reg [7:0] frame [0:9];
    // Decode one response frame from the physical TX pin.
    task automatic receive_byte(output [7:0] value);
        integer k;
        begin
            wait(uart_tx===1'b0);
            repeat(BIT_CLKS/2) @(posedge clk);
            for(k=0;k<8;k=k+1) begin
                repeat(BIT_CLKS) @(posedge clk);
                value[k]=uart_tx;
            end
            repeat(BIT_CLKS) @(posedge clk);
        end
    endtask
    task automatic receive_frame;
        integer k;
        reg [7:0] value;
        begin
            for(k=0;k<10;k=k+1) begin receive_byte(value); frame[k]=value; end
            frame_count=frame_count+1;
        end
    endtask

    initial begin
        repeat(120000) @(posedge clk);
        command(8'd1,8'd1);
        wait(dut.loop_mode==4'd1);
        if (!dut.LOOP_CONTROL_ENABLE) $fatal(1,"Loop path disabled");
        if (!dut.loop_tx_valid && !dut.control_uart_busy)
            $fatal(1,"top Loop command did not reach response serializer");
        $display("tb_mgc3130_uart_top_loop PASS");
        $finish;
    end
    initial begin #120_000_000; $fatal(1,"timeout frame_count=%0d",frame_count); end
endmodule
