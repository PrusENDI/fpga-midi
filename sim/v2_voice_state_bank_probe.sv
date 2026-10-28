module v2_voice_state_bank_probe (
    input  logic         clk,
    input  logic         rd_en,
    input  logic [4:0]   rd_addr,
    input  logic         wr_en,
    input  logic [4:0]   wr_addr,
    output logic [15:0] signature
);
    logic [207:0] rd_data;
    logic [207:0] wr_data;
    assign wr_data = {13{16'hA55A}} ^ {13{wr_addr, 11'd0}};
    (* keep_hierarchy = "yes" *)
    v2_voice_state_bank #(.USE_GOWIN_RAM(1)) bank (
        .clk, .rd_en, .rd_addr, .rd_data, .wr_en, .wr_addr, .wr_data
    );
    always_ff @(posedge clk)
        signature <= {16{^rd_data}};
endmodule
