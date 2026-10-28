`timescale 1ns/1ps
module tb_mgc3130_v2_top;
    logic clk_50m = 1'b0, uart_rx = 1'b1;
    tri mgc_sda, mgc_scl, mgc_ts, mgc_mclr;
    wire uart_tx, pcm5102a_bck, pcm5102a_lrck, pcm5102a_din;
    integer i;
    GSR GSR(.GSRI(1'b1));
    reg [7:0] inject_value;
    reg [15:0] sensor_x, sensor_y, sensor_z;
    reg [95:0] forced_event_value;

    always #5 clk_50m = ~clk_50m;
    mgc3130_v2_top #(.USE_MGC_READER(0), .UART_BAUD(1_000_000)) dut (
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
            // The V2 endpoint serializes a complete 22-byte response at the
            // configured UART baud before accepting the next command.
            repeat (4) @(posedge clk_50m);
            for (integer wait_i = 0; wait_i < 500000; wait_i = wait_i + 1) begin
                if (!dut.v2_tx_valid && !dut.uart_tx_busy) wait_i = 500000;
                else @(posedge clk_50m);
            end
            if (dut.v2_tx_valid || dut.uart_tx_busy)
                $fatal(1, "V2 UART response did not drain");
        end
    endtask

    task automatic sensor_report(input [15:0] x, input [15:0] y,
                                 input [15:0] z, input touch, input presence);
        begin
            sensor_x=x; sensor_y=y; sensor_z=z;
            force dut.x_position=sensor_x; force dut.y_position=sensor_y; force dut.z_position=sensor_z;
            force dut.xyz_valid=1'b1; force dut.report_valid=1'b1;
            force dut.touch_valid=1'b0; force dut.report_error=1'b0;
            @(posedge clk_50m); #1;
            force dut.report_valid=1'b0; force dut.xyz_valid=1'b0;
            release dut.x_position; release dut.y_position; release dut.z_position;
            release dut.xyz_valid; release dut.report_valid; release dut.touch_valid;
            release dut.report_error;
        end
    endtask

    task automatic inject_live_note(input [7:0] note_value);
        begin
            forced_event_value = 96'd0;
            forced_event_value[94:91] = 4'd1;
            forced_event_value[87:80] = 8'd0;
            forced_event_value[79:72] = 8'd1;
            forced_event_value[71:64] = note_value;
            forced_event_value[63:56] = 8'd100;
            force dut.live_event_data = forced_event_value;
            force dut.live_event_valid = 1'b1;
            repeat (2) @(posedge clk_50m);
            release dut.live_event_valid;
            release dut.live_event_data;
        end
    endtask

    initial begin
        repeat (25) @(posedge clk_50m);
        if (!dut.rst_sys_n) $fatal(1, "V2 reset did not release");
        if (!dut.pll_locked) $fatal(1, "V2 simulation PLL boundary not locked");
        force dut.degraded_frame = 1'b1;
        force dut.calibrated_gap = 1'b1;
        #1;
        if (dut.u_live.frame_degraded !== 1'b1 || dut.u_live.frame_gap !== 1'b1)
            $fatal(1, "LIVE rule engine did not receive degraded/gap validity");
        release dut.degraded_frame;
        release dut.calibrated_gap;

        // A valid control frame reaches the single V2 parser and changes mode.
        inject_control(8'h02, 8'h04, 8'h21, 32'h00000001);
        repeat (3) @(posedge clk_50m);
        $display("top cmd=%b op=%h addr=%h data=%h mode=%h err=%h", dut.cmd_valid, dut.cmd_op, dut.cmd_address, dut.cmd_data, dut.mode_reg, dut.protocol_error);
        if (dut.mode_reg !== 3'd1) $fatal(1, "MODE write did not reach V2 top");

        // PATCH CSR smoke: select one parameter, write/read its shadow value,
        // observe dirty status, then verify incomplete APPLY is reported.
        inject_control(8'h02, 8'h48, 8'h29, 32'h00000000); // family 0, track 0, index 0
        inject_control(8'h02, 8'h4c, 8'h2a, 32'h0000007b);
        inject_control(8'h01, 8'h4c, 8'h2b, 32'h00000000);
        if (dut.rsp_data !== 32'h0000007b || dut.rsp_error !== 8'h00)
            $fatal(1, "PATCH shadow readback mismatch data=%h err=%h", dut.rsp_data, dut.rsp_error);
        inject_control(8'h01, 8'h54, 8'h2c, 32'h00000000);
        if (dut.rsp_data[16] !== 1'b1)
            $fatal(1, "PATCH status did not report shadow dirty: %h", dut.rsp_data);
        inject_control(8'h02, 8'h5c, 8'h2d, 32'h80000000);
        if (dut.rsp_error !== 8'h09)
            $fatal(1, "PATCH incomplete APPLY was silently accepted: err=%h", dut.rsp_error);

        // WT CSR smoke: upload one sample through the top boundary, observe
        // the active/shadow status, and reject an incomplete table APPLY.
        // WT_DATA reads the active bank; active sample readback is covered by
        // the complete-table standalone gate because this upload is partial.
        inject_control(8'h02, 8'h60, 8'h2e, 32'h00002300); // table A, bank/band/octave metadata
        inject_control(8'h01, 8'h60, 8'h2f, 32'h00000000);
        if (dut.rsp_data[1:0] !== 2'd0 || dut.rsp_data[8] !== 1'b1 ||
            dut.rsp_data[9] !== 1'b1 || dut.rsp_data[15:12] !== 4'd2)
            $fatal(1, "WT selector readback mismatch data=%h", dut.rsp_data);
        inject_control(8'h02, 8'h64, 8'h30, 32'h00000000); // sample 0
        inject_control(8'h02, 8'h68, 8'h31, 32'h00001234);
        inject_control(8'h01, 8'h7c, 8'h32, 32'h00000000);
        if (dut.rsp_data[16] !== 1'b0 || dut.rsp_data[17] !== 1'b0 || dut.rsp_error !== 8'h00)
            $fatal(1, "WT partial status mismatch data=%h err=%h", dut.rsp_data, dut.rsp_error);
        inject_control(8'h02, 8'h78, 8'h33, 32'h80000000);
        if (dut.rsp_error !== 8'h0a)
            $fatal(1, "WT incomplete APPLY was silently accepted: err=%h", dut.rsp_error);

        // Selector-1 N-tone control must reach the final top and produce an
        // audio sample at the I2S boundary without allocating a voice.
        inject_control(8'h02, 8'ha0, 8'h26, 32'h00000101);
        inject_control(8'h01, 8'ha0, 8'h27, 32'h00000000);
        if (dut.rsp_data[31:8] !== 24'h040000) $fatal(1, "N-tone readback did not reach top");
        for (i = 0; i < 6000 && !dut.u_i2s.sample_valid; i = i + 1)
            @(posedge clk_50m);
        if (!dut.u_i2s.sample_valid) $fatal(1, "N-tone sample did not reach I2S");
        if (dut.voice_bitmap !== 32'd0) $fatal(1, "N-tone mode allocated a voice");

        // A valid XYZ report traverses latch, calibration, validity and cursor.
        sensor_report(16'd40000, 16'd32768, 16'd20000, 1'b0, 1'b1);
        repeat (4) @(posedge clk_50m);
        if (!dut.active_profile_valid) $fatal(1, "calibration profile did not commit");
        if (!dut.audio_cursor_valid && dut.cursor_stable_valid)
            $fatal(1, "cursor/audio boundary inconsistent");

        // Pure Z movement with no gate must not allocate a voice or emit NOTE_ON.
        sensor_report(16'd40000, 16'd32768, 16'd30000, 1'b0, 1'b0);
        repeat (4) @(posedge clk_50m);
        if (dut.voice_bitmap !== 32'd0) $fatal(1, "pure Z allocated a voice");

        // The record/commit path must reach the six-track store through CSR
        // control, rather than only changing the mode register.
        inject_control(8'h02, 8'h0c, 8'h22, 32'd2); // selected track 2
        inject_control(8'h02, 8'h18, 8'h23, 32'd1); // PREPARE_RECORD
        repeat (130) @(posedge clk_50m);
        if (!dut.recording) $fatal(1, "record CSR did not start recorder");
        inject_live_note(8'd60);
        repeat (8) @(posedge clk_50m);
        if (dut.record_track_count[2] == 0)
            $fatal(1, "recorded event did not reach selected track");
        inject_control(8'h02, 8'h28, 8'h24, 32'd1); // COMMIT_REQUEST
        repeat (8) @(posedge clk_50m);
        if (!dut.loop_commit_pending) $fatal(1, "commit CSR did not reach store");
        force dut.loop_boundary = 1'b1;
        @(posedge clk_50m); #1;
        release dut.loop_boundary;
        repeat (4) @(posedge clk_50m);
        if (!dut.loop_active_valid) $fatal(1, "committed loop bank is not active");
        inject_control(8'h01, 8'h00, 8'h28, 32'd0); // STATUS
        if (dut.rsp_data[8] !== 1'b1) $fatal(1, "STATUS did not report active Loop bank");
        inject_control(8'h02, 8'h04, 8'h25, 32'd4); // PLAY
        force dut.sample_index = 32'd0;
        // The DPB-backed store has a synchronous read latency. Hold the
        // loop tick at zero until the committed NOTE_ON reaches the voice
        // engine, with a bounded timeout for a broken hand-off.
        for (i = 0; i < 4000 && dut.voice_bitmap == 32'd0; i = i + 1)
            @(posedge clk_50m);
        release dut.sample_index;
        if (dut.voice_bitmap == 32'd0)
            $fatal(1, "PLAY did not deliver the committed loop event to voices");

        // The sample scheduler remains active independently of UART traffic.
        repeat (2500) @(posedge clk_50m);
        if (dut.sample_index == 0) $fatal(1, "sample scheduler stopped");
        $display("tb_mgc3130_v2_top PASS samples=%0d", dut.sample_index);
        $finish;
    end
endmodule
