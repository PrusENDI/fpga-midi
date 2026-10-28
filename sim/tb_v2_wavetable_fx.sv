`timescale 1ns/1ps
module tb_v2_wavetable_fx;
    logic clk = 0, rst_n = 0;
    logic wt_write_valid = 0, wt_write_ready;
    logic [1:0] wt_table = 0;
    logic [9:0] wt_index = 0;
    logic signed [15:0] wt_write_sample = 0;
    logic wt_apply_valid = 0, wt_apply_ready;
    logic [1:0] wt_apply_table = 0;
    logic [15:0] wt_apply_version = 0;
    logic loop_boundary = 0, idle = 0;
    logic wt_crc_valid = 0;
    logic [15:0] wt_expected_crc = 16'hffff;
    logic wt_active_valid, wt_shadow_valid, wt_apply_busy, wt_crc_error;
    logic [15:0] wt_active_version;
    logic [1:0] wt_active_table;
    logic [1:0] wt_read_table = 0;
    logic [9:0] wt_read_index = 0;
    logic signed [15:0] wt_read_sample;
    logic sample_ce = 0;
    logic signed [15:0] audio_in = 0, audio_out;
    logic fx_enable = 0;
    logic [1:0] fx_level = 0;
    logic [17:0] fx_gain_q16 = 18'h3ffff;
    logic [15:0] fx_cutoff_q16 = 16'hffff;
    logic [9:0] fx_delay_samples = 0;
    logic [15:0] fx_feedback_q15 = 0, fx_reverb_mix_q15 = 0;
    logic [1:0] fx_status_level;
    logic fx_clip;
    integer i;
    always #5 clk = ~clk;

    function automatic [15:0] crc_byte(input [15:0] crc_in, input [7:0] value);
        reg [15:0] c; integer b;
        begin c=crc_in^{value,8'h00}; for(b=0;b<8;b=b+1)c=c[15]?((c<<1)^16'h1021):(c<<1); crc_byte=c; end
    endfunction
    function automatic [15:0] table_crc;
        reg [15:0] c; integer j; integer signed v;
        begin c=16'hffff; c=crc_byte(c,8'h12); c=crc_byte(c,8'h34); c=crc_byte(c,8'hff); c=crc_byte(c,8'h00);
          for(j=2;j<1024;j=j+1) begin v=j-512; c=crc_byte(c,v[15:8]); c=crc_byte(c,v[7:0]); end table_crc=c; end
    endfunction

    v2_wavetable_loader #(.TABLES(3), .SAMPLES(1024)) wt (.*);
    v2_fx_lite fx (.*);

    task automatic write_sample(input integer idx, input integer value);
        begin
            @(negedge clk);
            wt_table = 0; wt_index = idx[9:0]; wt_write_sample = value[15:0]; wt_write_valid = 1;
            while (!wt_write_ready) @(negedge clk);
            @(posedge clk); #1; wt_write_valid = 0;
        end
    endtask

    initial begin
        repeat (2) @(posedge clk); rst_n = 1;
        write_sample(0, 16'sh1234);
        write_sample(1, -16'sh0100);
        @(negedge clk); wt_apply_valid = 1; wt_apply_table = 0; wt_apply_version = 0;
        @(posedge clk); #1; wt_apply_valid = 0;
        if (wt_active_version !== 0 || wt_active_valid) $fatal(1, "incomplete table applied");
        for (i = 2; i < 1024; i = i + 1) write_sample(i, i - 512);
        @(negedge clk); wt_expected_crc = table_crc(); wt_table = 0; wt_crc_valid = 1;
        $display("expected_crc=%h", table_crc());
        @(posedge clk); #1; wt_crc_valid = 0;
        @(negedge clk); wt_apply_valid = 1; wt_apply_table = 0; wt_apply_version = 0;
        @(posedge clk); #1; wt_apply_valid = 0;
        idle = 1; while (wt_apply_busy) @(posedge clk); @(posedge clk); #1; idle = 0;
        if (!wt_active_valid || wt_active_version !== 16'd1) $fatal(1, "complete table did not apply valid=%b ver=%0d crc_err=%b expected=%h", wt_active_valid, wt_active_version, wt_crc_error, wt_expected_crc);
        wt_read_index = 0; @(posedge clk); #1;
        if (wt_read_sample !== 16'sh1234) $fatal(1, "active sample mismatch");
        fx_enable = 1; fx_level = 2; fx_delay_samples = 10; fx_feedback_q15 = 16'd12000;
        fx_reverb_mix_q15 = 16'd8000; sample_ce = 1; audio_in = 16'sh1000;
        repeat (20) begin @(posedge clk); #1; end
        sample_ce = 0;
        if (fx_status_level !== 2'd2 || fx_clip) $fatal(1, "fx status/clip failure");
        $display("tb_v2_wavetable_fx PASS active_version=%0d fx_level=%0d", wt_active_version, fx_status_level);
        $finish;
    end
endmodule
