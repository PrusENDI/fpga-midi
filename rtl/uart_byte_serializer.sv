module uart_byte_serializer #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
) (
    input wire clk, input wire rst,
    input wire in_valid, output wire in_ready, input wire [7:0] in_data,
    output wire tx, output wire busy
);
    reg start;
    reg [7:0] data;
    wire uart_busy;
    assign in_ready = !uart_busy && !start;
    assign busy = uart_busy || start;
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .start(start), .data(data), .tx(tx), .busy(uart_busy)
    );
    always @(posedge clk) begin
        if (rst) begin
            start <= 1'b0;
            data <= 8'h00;
        end else begin
            start <= 1'b0;
            if (in_valid && in_ready) begin
                data <= in_data;
                start <= 1'b1;
            end
        end
    end
endmodule
