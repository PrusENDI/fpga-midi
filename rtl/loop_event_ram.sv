// Project-owned 128 x 64 true dual-port memory, single 50 MHz clock.
// Reads complete after one rising edge. Disabled ports and writes hold output.
// Memory is never reset: loop_event_store owns validity metadata.
// Simultaneous accesses to the same address with either port writing are
// forbidden; the store keeps playback on active and writes on shadow.
module loop_event_ram #(
    parameter integer USE_GOWIN_RAM = 1
) (
    input wire clk,
    input wire a_en, a_we,
    input wire [6:0] a_addr,
    input wire [63:0] a_wdata,
    output wire [63:0] a_rdata,
    input wire b_en, b_we,
    input wire [6:0] b_addr,
    input wire [63:0] b_wdata,
    output wire [63:0] b_rdata
);
    generate
        if (USE_GOWIN_RAM) begin : g_gowin
            // GW5A DPB supports at most 16 bits per true dual-port lane.
            // Physical depth 1024, logical depth 128; four lanes give 64 bits.
            // ADA/B[13:4] = word address; [1:0] are BYTE WRITE ENABLES.
            // Setting these to 00 silently suppresses writes on GW5A.
            for (genvar lane=0; lane<4; lane=lane+1) begin : g_lane
                DPB #(
                    .BIT_WIDTH_0(16), .BIT_WIDTH_1(16),
                    .READ_MODE0(1'b0), .READ_MODE1(1'b0),
                    .WRITE_MODE0(2'b00), .WRITE_MODE1(2'b00),
                    .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
                    .RESET_MODE("SYNC")
                ) ram (
                    .CLKA(clk), .CLKB(clk),
                    .CEA(a_en), .CEB(b_en), .OCEA(1'b1), .OCEB(1'b1),
                    .WREA(a_we), .WREB(b_we), .RESETA(1'b0), .RESETB(1'b0),
                    .BLKSELA(3'b000), .BLKSELB(3'b000),
                    .ADA({3'b000,a_addr,4'b0011}),
                    .ADB({3'b000,b_addr,4'b0011}),
                    .DIA(a_wdata[lane*16 +: 16]), .DIB(b_wdata[lane*16 +: 16]),
                    .DOA(a_rdata[lane*16 +: 16]), .DOB(b_rdata[lane*16 +: 16])
                );
            end
        end else begin : g_rtl
            reg [63:0] mem [0:127];
            reg [63:0] a_q, b_q;
            assign a_rdata = a_q;
            assign b_rdata = b_q;
            always @(posedge clk) begin
                if (a_en) begin
                    if (a_we) mem[a_addr] <= a_wdata;
                    else a_q <= mem[a_addr];
                end
            end
            always @(posedge clk) begin
                if (b_en) begin
                    if (b_we) mem[b_addr] <= b_wdata;
                    else b_q <= mem[b_addr];
                end
            end
        end
    endgenerate
endmodule
