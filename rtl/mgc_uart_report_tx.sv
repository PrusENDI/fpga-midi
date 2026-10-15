module mgc_uart_report_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        report_valid,
    input  wire [15:0] x_position,
    input  wire [15:0] y_position,
    input  wire [15:0] z_position,
    input  wire [7:0]  gesture_code,
    input  wire        xyz_valid,
    input  wire        report_error,
    output wire       uart_tx,
    output wire       busy
);
    reg       tx_start;
    reg [7:0] tx_data;
    wire      tx_busy;
    reg [7:0] frame [0:13];
    reg [3:0] index;
    reg [7:0] sequence;
    reg       sending;
    reg       launch_pending;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk   (clk),
        .rst   (!rst_n),
        .start (tx_start),
        .data  (tx_data),
        .tx    (uart_tx),
        .busy  (tx_busy)
    );

    assign busy = sending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_start <= 1'b0;
            tx_data  <= 8'h00;
            index    <= 4'd0;
            sequence <= 8'h00;
            sending  <= 1'b0;
            launch_pending <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            if (report_valid && !sending) begin
                frame[0]  <= 8'hAA;
                frame[1]  <= 8'h55;
                frame[2]  <= 8'h0A;
                frame[3]  <= 8'h01;
                frame[4]  <= sequence;
                frame[5]  <= x_position[7:0];
                frame[6]  <= x_position[15:8];
                frame[7]  <= y_position[7:0];
                frame[8]  <= y_position[15:8];
                frame[9]  <= z_position[7:0];
                frame[10] <= z_position[15:8];
                frame[11] <= gesture_code;
                frame[12] <= {6'b0, report_error, xyz_valid};
                frame[13] <= 8'h0A ^ 8'h01 ^ sequence ^
                             x_position[7:0] ^ x_position[15:8] ^
                             y_position[7:0] ^ y_position[15:8] ^
                             z_position[7:0] ^ z_position[15:8] ^
                             gesture_code ^ {6'b0, report_error, xyz_valid};
                index    <= 4'd0;
                sending  <= 1'b1;
                // Preload byte 0. The start pulse is issued on the next clock,
                // after tx_data has been registered.
                tx_data  <= 8'hAA;
                launch_pending <= 1'b1;
                sequence <= sequence + 1'b1;
            end else if (launch_pending) begin
                tx_start <= 1'b1;
                launch_pending <= 1'b0;
            end else if (sending && !tx_busy && !tx_start && !launch_pending) begin
                if (index == 4'd13) begin
                    sending <= 1'b0;
                end else begin
                    index <= index + 1'b1;
                    tx_data <= frame[index + 1'b1];
                    launch_pending <= 1'b1;
                end
            end
        end
    end
endmodule
