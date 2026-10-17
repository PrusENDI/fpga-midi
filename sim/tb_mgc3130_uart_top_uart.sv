`timescale 1ns/1ps
module tb_mgc3130_uart_top_uart;
    reg clk = 0;
    always #10 clk = ~clk;
    GSR GSR(.GSRI(1'b1));
    tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
    pullup(mgc_sda); pullup(mgc_scl); pullup(mgc_ts); pullup(mgc_mclr);
    reg uart_rx = 1'b1;
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

    localparam integer BIT_CLKS = 434;
    task automatic tx_bit(input bit value);
        begin uart_rx = value; repeat(BIT_CLKS) @(posedge clk); end
    endtask
    task automatic tx_byte(input [7:0] value);
        integer k;
        begin
            tx_bit(1'b0);
            for (k = 0; k < 8; k = k + 1) tx_bit(value[k]);
            tx_bit(1'b1);
        end
    endtask
    task automatic send_status;
        begin
            tx_byte(8'h55); tx_byte(8'haa); tx_byte(8'h00); tx_byte(8'd4);
            tx_byte(8'h00); tx_byte(8'h00); tx_byte(8'h00); tx_byte(8'h00);
            tx_byte(8'h01); tx_byte(8'h05);
        end
    endtask
    task automatic rx_byte(output [7:0] value);
        integer k;
        begin
            wait (uart_tx === 1'b0);
            repeat(BIT_CLKS/2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                repeat(BIT_CLKS) @(posedge clk);
                value[k] = uart_tx;
            end
            repeat(BIT_CLKS) @(posedge clk);
        end
    endtask

    integer i;
    reg [7:0] value;
    reg [7:0] previous;
    reg found;
    reg [7:0] ack [0:7];
    initial begin
        repeat(120000) @(posedge clk); // wait for reset/startup and banner
        send_status();
        repeat(10000) @(posedge clk);
        $display("after command mode=%0d loop_tx_valid=%b control_busy=%b phy_valid=%b rx_valid=%b rx_data=%02x",
                 dut.loop_mode, dut.loop_tx_valid, dut.control_uart_busy,
                 dut.u_loop_control_path.command_rx.phy_valid,
                 dut.u_loop_control_path.command_rx.rx_valid,
                 dut.u_loop_control_path.command_rx.rx_data);
        previous = 8'h00;
        found = 1'b0;
        for (i = 0; i < 40; i = i + 1) begin
            rx_byte(value);
            if (previous == 8'haa && value == 8'h55) begin
                found = 1'b1;
                rx_byte(ack[0]); rx_byte(ack[1]); rx_byte(ack[2]); rx_byte(ack[3]);
                rx_byte(ack[4]); rx_byte(ack[5]); rx_byte(ack[6]); rx_byte(ack[7]);
                i = 40;
            end
            previous = value;
        end
        if (!found) $fatal(1, "no ACK frame received");
        if (ack[0] !== 8'h00 || ack[1] !== 8'h00 || ack[6] !== 8'h01)
            $fatal(1, "bad ACK opcode/status/sequence: %02x %02x %02x", ack[0], ack[1], ack[6]);
        $display("tb_mgc3130_uart_top_uart PASS");
        $finish;
    end
    initial begin
        #120_000_000;
        $fatal(1, "timeout");
    end
endmodule
