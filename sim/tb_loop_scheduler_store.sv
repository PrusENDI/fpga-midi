`timescale 1ns/1ps
module tb_loop_scheduler_store #(parameter USE_GOWIN_RAM=1);
    reg clk=0;
    always #10 clk=~clk;
    GSR GSR (.GSRI(1'b1));
    reg rst_n=0, run=0, stop=0, flush=0, reset_position=0;
    wire read_enable, read_valid, read_slot_valid;
    wire [5:0] read_index;
    wire [63:0] read_data, event_data;
    wire event_valid, sixteenth_ce, loop_boundary, stall, fault_valid;
    reg event_ready=1;
    wire [6:0] loop_tick;
    wire [7:0] fault_code;
    wire [31:0] fault_info;
    wire heartbeat_toggle;
    wire [15:0] active_bpm;
    loop_scheduler #(.CLK_HZ(12000)) scheduler (
        .clk(clk), .rst_n(rst_n), .run(run), .stop(stop), .flush(flush),
        .reset_position(reset_position), .bpm_value(16'd120),
        .read_enable(read_enable), .read_index(read_index), .read_valid(read_valid),
        .read_slot_valid(read_slot_valid), .read_data(read_data),
        .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
        .sixteenth_ce(sixteenth_ce), .loop_tick(loop_tick), .loop_boundary(loop_boundary),
        .stall(stall), .fault_valid(fault_valid), .fault_code(fault_code),
        .fault_info(fault_info), .heartbeat_toggle(heartbeat_toggle), .active_bpm(active_bpm));
    reg manual_boundary=0, ctrl_valid=0, write_valid=0;
    reg [2:0] ctrl_op=0;
    reg [3:0] write_slot=0;
    reg [63:0] write_data=0;
    wire ctrl_ready, ctrl_done, write_ready, active_bank, shadow_bank;
    wire commit_pending, commit_ack, busy, active_valid;
    wire [19:0] record_count;
    wire [3:0] overflow;
    loop_event_store #(.USE_GOWIN_RAM(USE_GOWIN_RAM)) store (
        .clk(clk), .rst_n(rst_n), .abort(1'b0), .loop_boundary(loop_boundary | manual_boundary),
        .ctrl_valid(ctrl_valid), .ctrl_ready(ctrl_ready), .ctrl_op(ctrl_op), .ctrl_track(2'b0),
        .ctrl_done(ctrl_done), .write_valid(write_valid), .write_ready(write_ready),
        .write_track(2'b0), .write_slot(write_slot), .write_data(write_data),
        .read_enable(read_enable), .read_index(read_index), .read_valid(read_valid),
        .read_slot_valid(read_slot_valid), .read_data(read_data), .active_bank(active_bank),
        .shadow_bank(shadow_bank), .commit_pending(commit_pending), .commit_ack(commit_ack),
        .busy(busy), .record_count(record_count), .overflow(overflow), .active_valid(active_valid));

    function automatic [63:0] note(input [6:0] pitch, input [6:0] tick, input [6:0] duration);
        note={2'b0,4'b0,8'd0,8'd200,8'd0,8'd100,pitch,duration,tick,2'b0,3'd0};
    endfunction
    task command(input [2:0] op);
        begin
            @(negedge clk); ctrl_op=op; ctrl_valid=1;
            #1; if (!ctrl_ready) $fatal(1,"store command blocked");
            @(negedge clk); ctrl_valid=0;
        end
    endtask
    task append(input [3:0] slot, input [63:0] data);
        begin
            @(negedge clk); write_slot=slot; write_data=data; write_valid=1;
            #1; if (!write_ready) $fatal(1,"store append blocked");
            @(negedge clk); write_valid=0;
        end
    endtask

    integer seen=0, cycles=0, first_tick_cycle=-1, bank_swaps=0;
    reg first_bank;
    always @(posedge clk) begin
        cycles=cycles+1;
        if (rst_n && fault_valid) $fatal(1,"scheduler fault %h info %h",fault_code,fault_info);
        if (run && sixteenth_ce && first_tick_cycle<0) first_tick_cycle=cycles;
        if (run && loop_boundary) begin
            // 128 FULL 16th-note periods at 120 BPM and 12 kHz test clock.
            // Permit bounded boundary-event/drain latency, never shorten tick127.
            if (cycles-first_tick_cycle<191998 || cycles-first_tick_cycle>192020)
                $fatal(1,"loop length wrong: %0d clocks",cycles-first_tick_cycle);
        end
        if (run && commit_ack) bank_swaps=bank_swaps+1;
        if (rst_n && event_valid && event_ready) begin
            case(seen)
                0: if(event_data[2:0]!==0 || event_data[25:19]!==60 || event_data[11:5]!==0)
                       $fatal(1,"first tick must play old-bank note60: %h",event_data);
                1: if(event_data[2:0]!==1 || event_data[25:19]!==60 || event_data[11:5]!==1)
                       $fatal(1,"duration note-off missing: %h",event_data);
                2: if(event_data[2:0]!==0 || event_data[25:19]!==67 || event_data[11:5]!==127)
                       $fatal(1,"last tick missing: %h",event_data);
                3: if(event_data[2:0]!==4) $fatal(1,"boundary must close voices first");
                4: if(event_data[2:0]!==3) $fatal(1,"boundary event ordering");
                5: begin
                    if(event_data[2:0]!==0 || event_data[25:19]!==72 || event_data[11:5]!==0)
                        $fatal(1,"new bank tick0 not played: %h",event_data);
                    if(active_bank===first_bank || commit_pending || bank_swaps!=1)
                        $fatal(1,"scheduler read before store bank swap");
                end
                6: if(event_data[2:0]!==1 || event_data[25:19]!==72 || event_data[11:5]!==2)
                       $fatal(1,"new-bank duration note-off");
                7: if(event_data[2:0]!==4) $fatal(1,"STOP must close voices");
                default: $fatal(1,"unexpected duplicate/post-stop event %h",event_data);
            endcase
            seen=seen+1;
        end
    end
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        append(0,note(60,0,1)); append(1,note(67,127,0)); command(3);
        @(negedge clk); manual_boundary=1;
        @(negedge clk); manual_boundary=0; first_bank=active_bank;
        // Replace just track0 in shadow while active continues to own its data.
        command(5); wait(ctrl_done); @(negedge clk);
        append(0,note(72,0,2)); command(3);
        @(negedge clk); run=1;
        wait(seen==7);
        @(negedge clk); stop=1;
        @(negedge clk); stop=0;
        wait(seen==8);
        repeat(2000) @(negedge clk);
        if(loop_tick!==0 || !active_valid || active_bank===first_bank || seen!=8)
            $fatal(1,"STOP corrupted active bank/position or restarted");
        $display("tb_loop_scheduler_store PASS"); $finish;
    end
    initial begin #20000000; $fatal(1,"scheduler/store test timeout"); end
endmodule
