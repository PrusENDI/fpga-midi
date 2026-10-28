`timescale 1ns/1ps
module tb_mgc3130_v2_top_commit_timeout;
    logic clk_50m = 1'b0, uart_rx = 1'b1;
    tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
    wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;
    integer i;
    logic [7:0] inject_value;

    always #5 clk_50m = ~clk_50m;
    GSR GSR(.GSRI(1'b1));
    mgc3130_v2_top #(.USE_MGC_READER(0), .USE_POTTS(0),
                     .BOUNDARY_TIMEOUT_CYCLES(32'd300_000), .UART_BAUD(1_000_000)) dut (
        .clk_50m(clk_50m), .mgc_sda(mgc_sda), .mgc_scl(mgc_scl), .mgc_ts(mgc_ts),
        .mgc_mclr(mgc_mclr), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .pcm5102a_bck(pcm5102a_bck), .pcm5102a_lrck(pcm5102a_lrck), .pcm5102a_din(pcm5102a_din)
    );

    function automatic [15:0] crc_byte(input [15:0] crc_in, input [7:0] value);
        reg [15:0] c; integer b;
        begin
            c = crc_in ^ {value,8'h00};
            for (b = 0; b < 8; b = b + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction

    task automatic inject_byte(input [7:0] value);
        begin
            inject_value = value;
            force dut.uart_byte = inject_value;
            force dut.uart_byte_valid = 1'b1;
            @(posedge clk_50m); #1;
            force dut.uart_byte_valid = 1'b0;
            @(posedge clk_50m); #1;
            release dut.uart_byte_valid;
            release dut.uart_byte;
        end
    endtask

    task automatic inject_control(input [7:0] op, input [7:0] address,
                                   input [7:0] seq, input [31:0] data);
        reg [7:0] b [0:10]; reg [15:0] c; integer k;
        begin
            b[0]=8'ha5; b[1]=8'h02; b[2]=op; b[3]=address; b[4]=seq;
            b[5]=data[31:24]; b[6]=data[23:16]; b[7]=data[15:8]; b[8]=data[7:0];
            c=16'hffff; for(k=0;k<9;k=k+1)c=crc_byte(c,b[k]);
            b[9]=c[15:8]; b[10]=c[7:0];
            for(k=0;k<11;k=k+1) inject_byte(b[k]);
            repeat (4) @(posedge clk_50m);
            for (integer wait_i = 0; wait_i < 500000; wait_i = wait_i + 1) begin
                if (!dut.v2_tx_valid && !dut.uart_tx_busy) wait_i = 500000;
                else @(posedge clk_50m);
            end
            if (dut.v2_tx_valid || dut.uart_tx_busy) $fatal(1, "UART response did not drain");
        end
    endtask

    initial begin
        repeat (25) @(posedge clk_50m);
        if (!dut.rst_sys_n || !dut.pll_locked) $fatal(1, "reset/PLL did not release");
        inject_control(8'h02, 8'h04, 8'h51, 32'd2); // RECORD
        inject_control(8'h02, 8'h0c, 8'h52, 32'd0); // track 0
        inject_control(8'h02, 8'h18, 8'h53, 32'd1); // PREPARE_RECORD
        repeat (260) @(posedge clk_50m);
        if (!dut.recording || dut.loop_busy) $fatal(1, "record plane did not become ready");
        inject_control(8'h02, 8'h28, 8'h54, 32'd1); // COMMIT_REQUEST
        if (!dut.loop_commit_pending) $fatal(1, "commit request did not become pending");
        for (i = 0; i < 350_000; i = i + 1) @(posedge clk_50m);
        if (dut.loop_commit_pending || !dut.loop_commit_timeout || dut.loop_active_valid)
            $fatal(1, "top commit timeout policy failed pending=%b timeout=%b active=%b",
                   dut.loop_commit_pending, dut.loop_commit_timeout, dut.loop_active_valid);
        if (dut.sample_index == 0) $fatal(1, "sample scheduler was blocked by commit wait");
        $display("tb_mgc3130_v2_top_commit_timeout PASS wait_cycles=%0d samples=%0d",
                 dut.loop_commit_wait_cycles, dut.sample_index);
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "top commit timeout test timed out");
    end
endmodule
