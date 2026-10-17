// One-shot UART banner used to prove that the programmed FPGA reaches the
// board USB-UART TX pin.  The banner is deliberately sent before the binary
// Loop mailbox is enabled; it contains no AA 55 sync pair, so the PC client
// safely discards it while a terminal can still display it.
module uart_banner_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire clk,
    input  wire rst,
    input  wire enable,
    output wire tx,
    output wire busy
);
    localparam integer BANNER_LEN = 17;
    reg sending;
    reg started;
    reg [4:0] index;
    wire byte_ready;
    wire serializer_busy;

    function [7:0] banner_char;
        input [4:0] n;
        begin
            case (n)
                0:  banner_char = "L";
                1:  banner_char = "O";
                2:  banner_char = "O";
                3:  banner_char = "P";
                4:  banner_char = " ";
                5:  banner_char = "U";
                6:  banner_char = "A";
                7:  banner_char = "R";
                8:  banner_char = "T";
                9:  banner_char = " ";
                10: banner_char = "R";
                11: banner_char = "E";
                12: banner_char = "A";
                13: banner_char = "D";
                14: banner_char = "Y";
                15: banner_char = 8'h0d;
                16: banner_char = 8'h0a;
                default: banner_char = 8'h0a;
            endcase
        end
    endfunction

    uart_byte_serializer #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_serializer (
        .clk      (clk),
        .rst      (rst),
        .in_valid (sending),
        .in_ready (byte_ready),
        .in_data  (banner_char(index)),
        .tx       (tx),
        .busy     (serializer_busy)
    );

    assign busy = sending || serializer_busy;

    always @(posedge clk) begin
        if (rst) begin
            sending <= 1'b0;
            started <= 1'b0;
            index   <= 5'd0;
        end else begin
            if (enable && !started) begin
                started <= 1'b1;
                sending <= 1'b1;
                index   <= 5'd0;
            end else if (sending && byte_ready) begin
                if (index == BANNER_LEN - 1) begin
                    sending <= 1'b0;
                end else begin
                    index <= index + 1'b1;
                end
            end
        end
    end
endmodule
