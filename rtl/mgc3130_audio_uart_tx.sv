// 48 kHz, 8-bit unsigned mono PCM stream over 921600 8N1 UART.
// Frame: A5 5A sequence length(32) payload[32] checksum.
module mgc3130_audio_uart_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200,
    parameter integer SAMPLE_HZ = 48_000,
    parameter integer STREAM_HZ = 48_000
) (
    input wire clk,
    input wire rst,
    input wire sample_valid,
    input wire signed [15:0] mixed_sample,
    output wire tx,
    output wire busy
);
    localparam integer DECIMATE = SAMPLE_HZ / STREAM_HZ;
    localparam integer PAYLOAD = 32;
    reg [2:0] decimate_count;
    reg [5:0] payload_index;
    reg [7:0] sequence;
    reg [7:0] checksum;
    reg [7:0] payload [0:31];
    reg [5:0] capture_index;
    reg [7:0] tx_data;
    reg tx_start;
    reg sending;
    wire tx_busy;
    wire [7:0] pcm_sample = mixed_sample[15:8] + 8'd128;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst(rst), .start(tx_start), .data(tx_data),
        .tx(tx), .busy(tx_busy)
    );
    assign busy = sending;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            decimate_count <= 0;
            payload_index <= 0;
            capture_index <= 0;
            sequence <= 0;
            checksum <= 0;
            tx_data <= 0;
            tx_start <= 0;
            sending <= 0;
        end else begin
            tx_start <= 0;
            if (!sending) begin
                if (sample_valid) begin
                    if (decimate_count == DECIMATE - 1) begin
                        decimate_count <= 0;
                        payload[capture_index] <= pcm_sample;
                        if (capture_index == PAYLOAD - 1) begin
                            sending <= 1;
                            payload_index <= 0;
                            capture_index <= 0;
                            checksum <= 8'h20 ^ sequence;
                            tx_data <= 8'hA5;
                            tx_start <= 1;
                        end else begin
                            capture_index <= capture_index + 1'b1;
                        end
                    end else begin
                        decimate_count <= decimate_count + 1'b1;
                    end
                end
            end else if (!tx_busy && !tx_start) begin
                if (payload_index == 0) begin
                    tx_data <= 8'h5A;
                    tx_start <= 1;
                    payload_index <= 1;
                end else if (payload_index == 1) begin
                    tx_data <= sequence;
                    tx_start <= 1;
                    payload_index <= 2;
                end else if (payload_index == 2) begin
                    tx_data <= PAYLOAD;
                    tx_start <= 1;
                    payload_index <= 3;
                end else if (payload_index < PAYLOAD + 3) begin
                    tx_data <= payload[payload_index - 3];
                    checksum <= checksum ^ payload[payload_index - 3];
                    tx_start <= 1;
                    payload_index <= payload_index + 1'b1;
                end else begin
                    // The final payload byte was already XORed into checksum
                    // in the preceding clock, before payload_index advanced.
                    tx_data <= checksum;
                    tx_start <= 1;
                    sending <= 0;
                    sequence <= sequence + 1'b1;
                end
            end
        end
    end
endmodule
