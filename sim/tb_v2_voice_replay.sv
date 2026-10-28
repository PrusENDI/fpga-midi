`timescale 1ns/1ps
module tb_v2_voice_replay;
    parameter integer USE_GOWIN_RAM = 0;
    logic clk=0, rst_n=0, sample_ce=0, event_valid=0;
    logic [95:0] event_data=0;
    wire event_ready, sample_valid, voice_overflow;
    wire signed [15:0] mixed_sample;
    wire [31:0] active_bitmap;
    wire [7:0] revoice_count;
    wire [15:0] voice_steal_count;
    wire [5:0] active_voice_count;
    logic [15:0] vibrato_hz_q8_8 = 16'd0;
    logic [15:0] vibrato_cents_q8_8 = 16'd0;
    wire [15:0] vibrato_phase;
    wire signed [15:0] vibrato_delta_cents;
    always #5 clk=~clk;
    GSR GSR (.GSRI(1'b1));
    v2_voice_engine_banked #(.USE_GOWIN_RAM(USE_GOWIN_RAM)) dut (.*);
    integer fd, fields, op, expected_sample, expected_overflow, expected_revoice;
    integer row=0, samples=0, wait_cycles;
    reg [95:0] word;
    reg [31:0] expected_bitmap;
    string vector_path;

    task automatic compare_state;
        begin
            if(active_bitmap !== expected_bitmap || voice_overflow !== expected_overflow[0] ||
               revoice_count !== expected_revoice[7:0])
                $fatal(1,"row=%0d op=%0d state bitmap=%h/%h overflow=%b/%b revoice=%d/%d",
                    row,op,active_bitmap,expected_bitmap,voice_overflow,expected_overflow[0],revoice_count,expected_revoice);
        end
    endtask

    task automatic wait_sample;
        integer difference;
        begin
            wait_cycles=0;
            while(!sample_valid) begin
                @(negedge clk); wait_cycles=wait_cycles+1;
                if(wait_cycles>80) $fatal(1,"sample deadline row=%0d",row);
            end
            difference=$signed(mixed_sample)-expected_sample;
            if(difference < -1 || difference > 1 || (^mixed_sample === 1'bx))
                $fatal(1,"sample mismatch row=%0d actual=%0d expected=%0d bitmap=%h pending=%b slotp=%0d hold0=%0d rel0=%b note0=%0d active0=%b rdslot=%0d rdrel=%b rdenv=%0d",
                    row,$signed(mixed_sample),expected_sample,active_bitmap,dut.steal_pending,
                    dut.steal_slot_pending,dut.steal_hold[0],dut.releasing[0],dut.note[0],dut.active[0],dut.rd_slot,dut.rd_releasing,dut.rd_envelope);
            samples=samples+1;
            compare_state();
        end
    endtask

    initial begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing VECTORS");
        fd=$fopen(vector_path,"r"); if(fd==0) $fatal(1,"open vectors");
        while(!$feof(fd)) begin
            fields=$fscanf(fd,"%d %h %d %h %d %d\n",op,word,expected_sample,expected_bitmap,expected_overflow,expected_revoice);
            if(fields!=6) $fatal(1,"malformed row %0d",row);
            row=row+1;
            if(op==0) begin
                @(negedge clk); rst_n=0; event_valid=0; sample_ce=0;
                repeat(3) @(negedge clk); rst_n=1; @(negedge clk); compare_state();
            end else if(op==1) begin
                @(negedge clk); event_data=word; event_valid=1;
                wait_cycles=0;
                while(!event_ready) begin
                    @(negedge clk); wait_cycles=wait_cycles+1;
                    if(wait_cycles>80) $fatal(1,"event deadline row=%0d",row);
                end
                @(negedge clk); event_valid=0; compare_state();
            end else if(op==4) begin
                // op=3 already held the command through its real handshake.
                compare_state();
            end else if(op==2 || op==3) begin
                @(negedge clk); sample_ce=1;
                @(negedge clk); sample_ce=0;
                if(op==3) begin
                    repeat(2) @(negedge clk);
                    event_data=word; event_valid=1;
                    if(event_ready) $fatal(1,"busy scan accepted event row=%0d",row);
                end
                wait_sample();
                if(op==3) begin
                    // Hold until the scan boundary, then perform one handshake.
                    while(!event_ready) @(negedge clk);
                    @(negedge clk); event_valid=0;
                end
            end else $fatal(1,"unknown op");
        end
        $display("tb_v2_voice_replay PASS rows=%0d samples=%0d ram=%0d tolerance=1LSB",row,samples,USE_GOWIN_RAM);
        $finish;
    end
    initial begin #10000000; $fatal(1,"replay watchdog"); end
endmodule
