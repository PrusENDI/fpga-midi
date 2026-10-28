`timescale 1ns/1ps
module tb_v2_patch_bank;
    logic clk = 0, rst_n = 0;
    logic [1:0] select_family = 0;
    logic [2:0] select_track = 0;
    logic [7:0] select_index = 0;
    logic write_valid = 0, write_ready;
    logic signed [31:0] write_value = 0, active_value, shadow_value;
    logic crc_valid = 0;
    logic [15:0] expected_crc = 16'hffff;
    logic apply_valid = 0, apply_ready;
    logic [15:0] expected_version = 0;
    logic idle = 0, loop_boundary = 0;
    logic [15:0] active_version;
    logic shadow_dirty, crc_ok, apply_busy;
    logic [7:0] last_error;
    integer i;
    integer values [0:19];
    always #5 clk = ~clk;

    function automatic [15:0] crc_byte(input [15:0] crc_in, input [7:0] value);
        reg [15:0] c; integer b;
        begin
            c = crc_in ^ {value,8'h00};
            for (b=0; b<8; b=b+1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction
    function automatic [15:0] patch_crc;
        reg [15:0] c; integer j; reg [31:0] v;
        begin
            c = 16'hffff;
            for (j=0; j<20; j=j+1) begin
                v = values[j];
                c = crc_byte(c,v[31:24]); c = crc_byte(c,v[23:16]);
                c = crc_byte(c,v[15:8]); c = crc_byte(c,v[7:0]);
            end
            patch_crc = c;
        end
    endfunction

    v2_patch_bank dut (.*);

    task automatic write_param(input integer idx, input integer value);
        begin
            @(negedge clk);
            select_index = idx[7:0]; write_value = value; write_valid = 1'b1;
            #1;
            if (!write_ready) $fatal(1, "valid patch rejected idx=%0d", idx);
            @(posedge clk); #1; write_valid = 1'b0;
        end
    endtask

    initial begin
        values[0]=0; values[1]=1; values[2]=2; values[3]=3; values[4]=4;
        values[5]=5; values[6]=6; values[7]=7; values[8]=8; values[9]=9;
        values[10]=10; values[11]=11; values[12]=12; values[13]=1; values[14]=14;
        values[15]=2; values[16]=1000; values[17]=17; values[18]=18; values[19]=19;
        repeat (2) @(posedge clk); rst_n = 1;
        select_index = 0; write_value = -1; write_valid = 1;
        #1 if (write_ready) $fatal(1, "out-of-range patch accepted");
        write_valid = 0;

        @(negedge clk); apply_valid = 1; expected_version = 0;
        @(posedge clk); #1; apply_valid = 0;
        if (last_error !== 8'h09 || apply_busy) $fatal(1, "incomplete patch was accepted error=%h", last_error);

        for (i=0; i<20; i=i+1) write_param(i, values[i]);
        @(negedge clk); expected_crc = patch_crc(); crc_valid = 1;
        @(posedge clk); #1; crc_valid = 0;
        @(negedge clk); apply_valid = 1; expected_version = 0;
        @(posedge clk); #1; apply_valid = 0; idle = 1;
        while (apply_busy) @(posedge clk);
        idle = 0;
        if (!crc_ok || active_version !== 16'd1 || shadow_dirty)
            $fatal(1, "patch apply failed crc_ok=%b version=%0d dirty=%b error=%h expected=%h acc=%h",
                   crc_ok, active_version, shadow_dirty, last_error, expected_crc, dut.crc_acc);
        select_index = 17; @(posedge clk); #1;
        if (active_value !== values[17]) $fatal(1, "active patch read mismatch %0d", active_value);
        $display("tb_v2_patch_bank PASS version=%0d crc=%h", active_version, expected_crc);
        $finish;
    end
endmodule
