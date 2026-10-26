// Double-buffered, tear-free V2 telemetry snapshot.
//
// capture_* is a control/sample-domain boundary. Once accepted, all fields
// are copied into the inactive 20-byte body and its CRC is calculated before
// the bank becomes visible to the byte serializer. TX backpressure only holds
// the selected byte; a later capture fills the other bank and never changes a
// frame already in flight.
module v2_telemetry_snapshot (
    input logic clk, input logic rst_n,
    input logic capture_valid, output logic capture_ready,
    input logic [7:0] capture_type, input logic [15:0] capture_sequence,
    input logic signed [15:0] capture_x, input logic signed [15:0] capture_y,
    input logic signed [15:0] capture_z, input logic [7:0] capture_note,
    input logic [7:0] capture_flags, input logic [7:0] capture_tick,
    input logic [31:0] capture_voice_bitmap, input logic [7:0] capture_fifo_level,
    input logic [7:0] capture_fault_code,
    output logic frame_valid, input logic frame_ready,
    output logic [7:0] frame_byte, output logic frame_last,
    output logic [7:0] dropped_captures
);
    logic [7:0] bank [0:1][0:21];
    logic active_bank;
    logic bank_full [0:1];
    logic [4:0] tx_index;
    logic [15:0] crc_tmp;
    integer i;

    function automatic logic [15:0] crc8_step(input logic [15:0] crc_in,
                                               input logic [7:0] byte_in);
        logic [15:0] c; integer b;
        begin
            c = crc_in ^ {byte_in,8'h00};
            for (b = 0; b < 8; b = b + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc8_step = c;
        end
    endfunction

    assign frame_valid = bank_full[active_bank];
    assign frame_byte = bank[active_bank][tx_index];
    assign frame_last = frame_valid && (tx_index == 21);
    // A capture can use the inactive bank while the active frame is being
    // transmitted. If both banks are full, preserve the in-flight snapshot.
    assign capture_ready = !bank_full[~active_bank];

    wire capture_accept = capture_valid && capture_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0] body_byte;
        if (!rst_n) begin
            active_bank <= 1'b0;
            bank_full[0] <= 1'b0; bank_full[1] <= 1'b0;
            tx_index <= 0;
            dropped_captures <= 0;
            for (i = 0; i < 22; i = i + 1) begin
                bank[0][i] <= 0; bank[1][i] <= 0;
            end
        end else begin
            if (frame_valid && frame_ready) begin
                if (tx_index == 21) begin
                    bank_full[active_bank] <= 1'b0;
                    // If the inactive bank is filled on this same edge, it is
                    // the next frame even though bank_full[~active_bank] is
                    // still the old value in this clocked block.
                    if (bank_full[~active_bank] || capture_accept)
                        active_bank <= ~active_bank;
                    tx_index <= 0;
                end else tx_index <= tx_index + 1'b1;
            end
            if (capture_valid) begin
                if (capture_ready) begin
                    bank[~active_bank][0] <= 8'h5A;
                    bank[~active_bank][1] <= 8'h02;
                    bank[~active_bank][2] <= capture_type;
                    bank[~active_bank][3] <= capture_sequence[15:8];
                    bank[~active_bank][4] <= capture_sequence[7:0];
                    bank[~active_bank][5] <= capture_x[15:8]; bank[~active_bank][6] <= capture_x[7:0];
                    bank[~active_bank][7] <= capture_y[15:8]; bank[~active_bank][8] <= capture_y[7:0];
                    bank[~active_bank][9] <= capture_z[15:8]; bank[~active_bank][10] <= capture_z[7:0];
                    bank[~active_bank][11] <= capture_note;
                    bank[~active_bank][12] <= capture_flags;
                    bank[~active_bank][13] <= capture_tick;
                    bank[~active_bank][14] <= capture_voice_bitmap[31:24];
                    bank[~active_bank][15] <= capture_voice_bitmap[23:16];
                    bank[~active_bank][16] <= capture_voice_bitmap[15:8];
                    bank[~active_bank][17] <= capture_voice_bitmap[7:0];
                    bank[~active_bank][18] <= capture_fifo_level;
                    bank[~active_bank][19] <= capture_fault_code;
                    crc_tmp = 16'hffff;
                    for (i = 0; i < 20; i = i + 1) begin
                        case (i)
                          0: body_byte = 8'h5A; 1: body_byte = 8'h02;
                          2: body_byte = capture_type;
                          3: body_byte = capture_sequence[15:8]; 4: body_byte = capture_sequence[7:0];
                          5: body_byte = capture_x[15:8]; 6: body_byte = capture_x[7:0];
                          7: body_byte = capture_y[15:8]; 8: body_byte = capture_y[7:0];
                          9: body_byte = capture_z[15:8]; 10: body_byte = capture_z[7:0];
                          11: body_byte = capture_note; 12: body_byte = capture_flags;
                          13: body_byte = capture_tick;
                          14: body_byte = capture_voice_bitmap[31:24];
                          15: body_byte = capture_voice_bitmap[23:16];
                          16: body_byte = capture_voice_bitmap[15:8];
                          17: body_byte = capture_voice_bitmap[7:0];
                          18: body_byte = capture_fifo_level;
                          default: body_byte = capture_fault_code;
                        endcase
                        crc_tmp = crc8_step(crc_tmp, body_byte);
                    end
                    bank[~active_bank][20] <= crc_tmp[15:8];
                    bank[~active_bank][21] <= crc_tmp[7:0];
                    bank_full[~active_bank] <= 1'b1;
                    if (!bank_full[active_bank]) active_bank <= ~active_bank;
                end else dropped_captures <= dropped_captures + 1'b1;
            end
        end
    end
endmodule
