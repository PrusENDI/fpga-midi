module uart_heartbeat #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200,
    parameter integer PERIOD_MS = 1000
) (
    input wire clk,
    input wire rst_n,
    output wire uart_tx,
    output wire busy
);
    localparam integer PERIOD_CLKS = (CLK_HZ / 1000) * PERIOD_MS;
    reg [31:0] timer;
    reg [4:0] index;
    reg sending;
    reg start;
    reg [7:0] data;
    wire tx_busy;
    reg [7:0] message [0:16];

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(!rst_n), .start(start), .data(data),
        .tx(uart_tx), .busy(tx_busy)
    );
    assign busy = sending;

    always @(*) begin
        message[0]  = "M"; message[1]  = "G"; message[2]  = "C";
        message[3]  = "3"; message[4]  = "1"; message[5]  = "3";
        message[6]  = "0"; message[7]  = " "; message[8]  = "U";
        message[9]  = "A"; message[10] = "R"; message[11] = "T";
        message[12] = " "; message[13] = "O"; message[14] = "K";
        message[15] = 8'h0d; message[16] = 8'h0a;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= 0; index <= 0; sending <= 0; start <= 0; data <= 0;
        end else begin
            start <= 0;
            if (!sending) begin
                if (timer == PERIOD_CLKS - 1) begin
                    timer <= 0; index <= 0; data <= message[0];
                    sending <= 1; start <= 1;
                end else timer <= timer + 1;
            end else if (!tx_busy) begin
                if (index == 5'd16) begin
                    sending <= 0;
                end else begin
                    index <= index + 1;
                    data <= message[index + 1];
                    start <= 1;
                end
            end
        end
    end
endmodule
