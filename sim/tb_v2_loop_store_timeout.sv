`timescale 1ns/1ps
module tb_v2_loop_store_timeout;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic abort = 1'b0;
    logic boundary = 1'b0;
    logic ctrl_valid = 1'b0;
    logic [2:0] ctrl_op = 3'd0;
    logic [2:0] ctrl_track = 3'd0;
    logic ctrl_ready, ctrl_done;
    logic write_valid = 1'b0;
    logic write_ready;
    logic [2:0] write_track = 3'd0;
    logic [4:0] write_slot = 5'd0;
    logic [95:0] write_data = 96'd0;
    logic read_enable = 1'b0;
    logic [2:0] read_track = 3'd0;
    logic [4:0] read_index = 5'd0;
    logic read_valid, read_slot_valid;
    logic [95:0] read_data;
    logic active_bank, shadow_bank, commit_pending, commit_ack, busy;
    logic [35:0] record_count;
    logic [5:0] overflow;
    logic active_valid;
    logic commit_timeout;
    logic [31:0] commit_wait_cycles;
    logic p_ctrl_ready, p_ctrl_done, p_write_ready, p_read_valid, p_read_slot_valid;
    logic [95:0] p_read_data;
    logic p_active_bank, p_shadow_bank, p_commit_pending, p_commit_ack, p_busy;
    logic [35:0] p_record_count;
    logic [5:0] p_overflow;
    logic p_active_valid, p_commit_timeout;
    logic [31:0] p_commit_wait_cycles;
    integer i;
    logic ack_seen, p_ack_seen;

    always #5 clk = ~clk;
    GSR GSR(.GSRI(1'b1));

    v2_loop_event_store_dpb #(.BOUNDARY_TIMEOUT_CYCLES(32'd8)) dut (
        .clk(clk), .rst_n(rst_n), .abort(abort), .loop_boundary(boundary),
        .ctrl_valid(ctrl_valid), .ctrl_ready(ctrl_ready), .ctrl_op(ctrl_op),
        .ctrl_track(ctrl_track), .ctrl_done(ctrl_done),
        .write_valid(write_valid), .write_ready(write_ready), .write_track(write_track),
        .write_slot(write_slot), .write_data(write_data),
        .read_enable(read_enable), .read_track(read_track), .read_index(read_index),
        .read_valid(read_valid), .read_slot_valid(read_slot_valid), .read_data(read_data),
        .active_bank(active_bank), .shadow_bank(shadow_bank), .commit_pending(commit_pending),
        .commit_ack(commit_ack), .busy(busy), .record_count(record_count),
        .overflow(overflow), .active_valid(active_valid), .commit_timeout(commit_timeout),
        .commit_wait_cycles(commit_wait_cycles)
    );

    v2_loop_event_store #(.BOUNDARY_TIMEOUT_CYCLES(32'd8)) portable (
        .clk(clk), .rst_n(rst_n), .abort(abort), .loop_boundary(boundary),
        .ctrl_valid(ctrl_valid), .ctrl_ready(p_ctrl_ready), .ctrl_op(ctrl_op),
        .ctrl_track(ctrl_track), .ctrl_done(p_ctrl_done),
        .write_valid(write_valid), .write_ready(p_write_ready), .write_track(write_track),
        .write_slot(write_slot), .write_data(write_data),
        .read_enable(read_enable), .read_track(read_track), .read_index(read_index),
        .read_valid(p_read_valid), .read_slot_valid(p_read_slot_valid), .read_data(p_read_data),
        .active_bank(p_active_bank), .shadow_bank(p_shadow_bank), .commit_pending(p_commit_pending),
        .commit_ack(p_commit_ack), .busy(p_busy), .record_count(p_record_count),
        .overflow(p_overflow), .active_valid(p_active_valid), .commit_timeout(p_commit_timeout),
        .commit_wait_cycles(p_commit_wait_cycles)
    );

    task automatic command(input [2:0] op);
        begin
            @(negedge clk);
            ctrl_op = op;
            ctrl_valid = 1'b1;
            while (!ctrl_ready) @(negedge clk);
            @(negedge clk);
            ctrl_valid = 1'b0;
            while (!ctrl_done) @(negedge clk);
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        // Add one event to the shadow bank, then request a commit.
        @(negedge clk);
        write_data = 96'h0000_0001_0000_003c_6400_0001;
        write_valid = 1'b1;
        while (!write_ready) @(negedge clk);
        @(negedge clk);
        write_valid = 1'b0;
        command(3'd3);
        if (!commit_pending || active_bank !== 1'b0)
            $fatal(1, "commit request did not become pending");
        // No boundary: timeout is deterministic and leaves the old active bank.
        for (i = 0; i < 12; i = i + 1) begin
            @(negedge clk);
            if (commit_ack) $fatal(1, "unexpected commit ack without boundary");
        end
        if (commit_pending || !commit_timeout || commit_ack || p_commit_pending || !p_commit_timeout || p_commit_ack)
            $fatal(1, "timeout policy failed pending=%b timeout=%b ack=%b", commit_pending, commit_timeout, commit_ack);
        if (active_bank !== 1'b0 || active_valid || p_active_bank !== 1'b0 || p_active_valid)
            $fatal(1, "active bank changed or became valid after timeout bank=%b/%b valid=%b/%b", active_bank, p_active_bank, active_valid, p_active_valid);
        if (commit_wait_cycles < 32'd7 || p_commit_wait_cycles < 32'd7)
            $fatal(1, "wait-cycle diagnostic too small: %0d/%0d", commit_wait_cycles, p_commit_wait_cycles);
        // A later prepare/commit still works, proving timeout does not poison the store.
        command(3'd5);
        @(negedge clk);
        write_data = 96'h0000_0001_0000_003d_6400_0002;
        write_valid = 1'b1;
        while (!write_ready) @(negedge clk);
        @(negedge clk);
        write_valid = 1'b0;
        command(3'd3);
        boundary = 1'b1;
        @(negedge clk);
        boundary = 1'b0;
        ack_seen = commit_ack;
        p_ack_seen = p_commit_ack;
        repeat (2) begin
            @(negedge clk);
            ack_seen = ack_seen || commit_ack;
            p_ack_seen = p_ack_seen || p_commit_ack;
        end
        if (!ack_seen || commit_pending || !active_valid || !p_ack_seen || p_commit_pending || !p_active_valid)
            $fatal(1, "post-timeout boundary commit failed ack_seen=%b/%b pending=%b/%b valid=%b/%b", ack_seen, p_ack_seen, commit_pending, p_commit_pending, active_valid, p_active_valid);
        $display("tb_v2_loop_store_timeout PASS wait_cycles=%0d/%0d", commit_wait_cycles, p_commit_wait_cycles);
        $finish;
    end

    initial begin
        #100_000;
        $fatal(1, "store timeout test timed out");
    end
endmodule
