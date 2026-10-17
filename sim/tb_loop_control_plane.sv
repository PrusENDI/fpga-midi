`timescale 1ns/1ps
module tb_loop_control_plane #(parameter USE_GOWIN_RAM=0);
    reg clk=0;always #5 clk=~clk;
    GSR GSR(.GSRI(1'b1));
    reg rst_n=0,rx_valid=0,tx_ready=1,record_start=0,in_valid=0,record_in_valid=0,adapter_idle=1,out_ready=1;
    wire rx_ready,tx_valid,in_ready,out_valid;
    reg [7:0] rx_data=0;wire [7:0] tx_data;
    reg [63:0] in_data=0,record_in_data=0;wire [63:0] out_data;wire record_in_ready;
    wire [3:0] mode;wire [1:0] selected_track;
    wire [15:0] bpm_shadow,active_bpm,start_enter,start_exit;
    wire [6:0] loop_tick;wire active_valid,fault_latched,live_enable,record_enable,play_enable,flush_events;wire [2:0] router_debug;wire [7:0] router_status;
    reg [15:0] report_count=0,xyz_count=0,sample_count=0;
    reg [7:0] note_on_count=0;
    reg [2:0] active_voice_count=0;
    reg [7:0] diag_flags=0;
    loop_control_plane #(.CLK_HZ(12000),.USE_GOWIN_RAM(USE_GOWIN_RAM),
        .OP_TIMEOUT_CYCLES(4000),.BOUNDARY_TIMEOUT_CYCLES(400000),.RX_TIMEOUT_CYCLES(100)) dut(.*);
    reg [7:0] response[0:9];integer reply_index=0;
    integer accepted[0:255],applied[0:255],rejected[0:255],errors[0:255];
    reg [31:0] reply_data[0:255];
    integer ons=0,offs=0,kills=0,i,j;reg [7:0] check_byte;
    always @(posedge clk) begin
        if(rst_n && tx_valid && tx_ready) begin
            response[reply_index]=tx_data;
            if(reply_index==9) begin
                if(response[0]!==8'haa || response[1]!==8'h55) $fatal(1,"bad ACK header");
                check_byte=0;for(j=2;j<9;j=j+1) check_byte=check_byte^response[j];
                if(check_byte!==response[9]) $fatal(1,"bad ACK checksum");
                case(response[3])
                    0: accepted[response[8]]=accepted[response[8]]+1;
                    1: applied[response[8]]=applied[response[8]]+1;
                    2: rejected[response[8]]=rejected[response[8]]+1;
                    4: errors[response[8]]=errors[response[8]]+1;
                    default: $fatal(1,"unexpected BUSY or ACK status");
                endcase
                reply_data[response[8]]={response[7],response[6],response[5],response[4]};
                reply_index=0;
            end else reply_index=reply_index+1;
        end
        if(rst_n && out_valid && out_ready) begin
            if(out_data[2:0]==0) ons=ons+1;
            if(out_data[2:0]==1) offs=offs+1;
            if(out_data[2:0]==4) kills=kills+1;
        end
    end
    task byte_in(input [7:0] b);
        begin
            @(negedge clk);rx_valid=1;rx_data=b;
            while(!rx_ready) @(negedge clk);
            @(negedge clk);rx_valid=0;
        end
    endtask
    task command(input [7:0] op,input [15:0] a0,input [15:0] a1,input [7:0] seq);
        begin
            byte_in(8'h55);byte_in(8'haa);byte_in(op);byte_in(4);
            byte_in(a0[7:0]);byte_in(a0[15:8]);byte_in(a1[7:0]);byte_in(a1[15:8]);byte_in(seq);
            byte_in(op^8'd4^a0[7:0]^a0[15:8]^a1[7:0]^a1[15:8]^seq);
        end
    endtask
    task wait_applied(input integer seq);
        integer limit;
        begin limit=0;while(applied[seq]==0 && limit<4000)begin @(negedge clk);limit=limit+1;end
            if(applied[seq]!=1 || accepted[seq]!=1) $fatal(1,"command%0d ACK timeout/mismatch mode=%0d",seq,mode);
        end
    endtask
    task gesture(input [6:0] pitch);
        begin
            @(negedge clk);in_data={2'd0,4'd0,8'd0,8'd180,8'd0,8'd100,pitch,7'd1,7'd0,2'd0,3'd0};in_valid=1;
            while(!in_ready) @(negedge clk);
            @(negedge clk);in_valid=0;
        end
    endtask
    integer count_before,kill_before,limit;
    initial begin
        for(i=0;i<256;i=i+1)begin accepted[i]=0;applied[i]=0;rejected[i]=0;errors[i]=0;reply_data[i]=0;end
        repeat(3) @(negedge clk);rst_n=1;
        command(4,0,0,1);repeat(100)@(negedge clk);
        if(rejected[1]!=1 || accepted[1]!=1 || mode!=0) $fatal(1,"PLAY empty must reject");
        command(2,180,0,2);wait_applied(2);
        command(1,1,0,3);wait_applied(3);if(mode!=1) $fatal(1,"LIVE transition");
        gesture(60);repeat(20)@(negedge clk);if(ons!=1) $fatal(1,"LIVE monitor delivery");
        command(5,0,0,4);wait_applied(4);if(mode!=0 || active_valid) $fatal(1,"STOP idle");
        command(6,0,0,5);wait_applied(5);if(mode!=2) $fatal(1,"RECORD arm");
        @(negedge clk);record_start=1;@(negedge clk);record_start=0;
        wait(mode==3);gesture(72);
        limit=0;while(mode!=5 && limit<140000)begin @(negedge clk);limit=limit+1;end
        if(mode!=5 || !active_valid || fault_latched) $fatal(1,"record did not commit/play mode=%0d fault=%b tick=%d",mode,fault_latched,loop_tick);
        count_before=ons;repeat(2000)@(negedge clk);
        if(ons<=count_before || offs==0) $fatal(1,"stored phrase did not replay");
        // Defer tempo until boundary; validated STOP preempts it even with TX blocked.
        tx_ready=0;command(2,120,0,6);repeat(40)@(negedge clk);
        kill_before=kills;command(5,0,0,7);repeat(100)@(negedge clk);
        if(mode!=0 || !active_valid || kills<=kill_before) $fatal(1,"urgent STOP blocked by ACK or damaged active");
        tx_ready=1;wait_applied(7);
        if(errors[6]!=1 || accepted[6]!=1) $fatal(1,"interrupted BPM command missing terminal ERROR");
        if(bpm_shadow!=180) $fatal(1,"canceled tempo proposal leaked into next PLAY");
        command(4,0,0,8);wait_applied(8);
        command(7,0,0,12);wait_applied(12);
        if(mode!=6) $fatal(1,"OVERDUB must arm at boundary");
        limit=0;while(mode!=7 && limit<140000)begin @(negedge clk);limit=limit+1;end
        if(mode!=7) $fatal(1,"OVERDUB did not begin at boundary");
        gesture(76);
        limit=0;while(mode!=5 && limit<140000)begin @(negedge clk);limit=limit+1;end
        if(mode!=5 || !active_valid || fault_latched) $fatal(1,"OVERDUB did not commit/play");
        count_before=ons;repeat(2000)@(negedge clk);
        if(ons<count_before+2) $fatal(1,"OVERDUB lost old or appended note");
        command(5,0,0,9);wait_applied(9);
        command(9,0,0,10);wait_applied(10);
        if(active_valid || mode!=0 || fault_latched) $fatal(1,"CLEAR_ALL did not clear committed Loop");
        command(12,8'h00,0,11);wait_applied(11);if(reply_data[11]!=0) $fatal(1,"STATUS CSR wrong");
        $display("tb_loop_control_plane PASS");$finish;
    end
    initial begin #20000000;$fatal(1,"control plane timeout mode=%d",mode);end
endmodule
