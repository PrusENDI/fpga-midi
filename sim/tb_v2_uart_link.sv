`timescale 1ns/1ps
module tb_v2_uart_link;
    import v2_contract_pkg::*;

    logic clk = 1'b0, rst_n = 1'b0;
    logic rx_valid = 1'b0;
    logic [7:0] rx_byte = 8'h00;
    logic cmd_valid, cmd_ready = 1'b0;
    logic [7:0] cmd_op, cmd_address, cmd_sequence;
    logic [31:0] cmd_data;
    logic rsp_valid = 1'b0, rsp_ready;
    logic [7:0] rsp_sequence = 0, rsp_status = 0, rsp_error = 0;
    logic [31:0] rsp_data = 0;
    logic rsp_terminal = 1'b0;
    logic tx_valid, tx_ready = 1'b1;
    logic [7:0] tx_byte;
    logic rx_busy, tx_busy;
    logic [7:0] protocol_error;
    integer i;

    always #5 clk = ~clk;

    v2_uart_link dut (.*);

    function automatic [15:0] crc_byte(input [15:0] crc_in, input [7:0] value);
        reg [15:0] c;
        integer b;
        begin
            c = crc_in ^ {value,8'h00};
            for (b = 0; b < 8; b = b + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction

    task automatic send_byte(input [7:0] value);
        begin
            @(negedge clk); rx_byte = value; rx_valid = 1'b1;
            @(negedge clk); rx_valid = 1'b0; rx_byte = 8'h00;
        end
    endtask

    task automatic send_frame(input [7:0] op, input [7:0] address,
                               input [7:0] seq, input [31:0] data,
                               input bit corrupt_crc);
        reg [7:0] b [0:10];
        reg [15:0] c;
        integer k;
        begin
            b[0] = V2_CONTROL_SOF; b[1] = V2_VERSION; b[2] = op;
            b[3] = address; b[4] = seq;
            b[5] = data[31:24]; b[6] = data[23:16];
            b[7] = data[15:8]; b[8] = data[7:0];
            c = 16'hffff;
            for (k = 0; k < 9; k = k + 1) c = crc_byte(c, b[k]);
            b[9] = c[15:8]; b[10] = c[7:0];
            if (corrupt_crc) b[10] = b[10] ^ 8'h01;
            for (k = 0; k < 11; k = k + 1) send_byte(b[k]);
        end
    endtask

    task automatic accept_command;
        begin
            while (!cmd_valid) @(posedge clk);
            if (!cmd_valid) $fatal(1, "command did not become valid");
            cmd_ready = 1'b1;
            @(posedge clk);
            cmd_ready = 1'b0;
        end
    endtask

    task automatic respond(input [7:0] seq, input [7:0] status,
                           input [7:0] error, input [31:0] data,
                           input bit terminal);
        begin
            while (!rsp_ready) @(posedge clk);
            @(negedge clk);
            rsp_sequence = seq; rsp_status = status; rsp_error = error;
            rsp_data = data; rsp_terminal = terminal; rsp_valid = 1'b1;
            @(posedge clk);
            @(negedge clk); rsp_valid = 1'b0;
        end
    endtask

    task automatic collect_frame(output reg [7:0] result [0:21]);
        integer k, wait_cycles;
        begin
            for (k = 0; k < 22; k = k + 1) begin
                wait_cycles = 0;
                while (!tx_valid) begin
                    @(negedge clk); wait_cycles = wait_cycles + 1;
                    if (wait_cycles > 200)
                        $fatal(1, "TX frame did not start at byte %0d", k);
                end
                result[k] = tx_byte;
                @(posedge clk); #1;
            end
        end
    endtask

    function automatic [15:0] frame_crc(input reg [7:0] result [0:21]);
        reg [15:0] c;
        integer k;
        begin
            c = 16'hffff;
            for (k = 0; k < 20; k = k + 1) c = crc_byte(c, result[k]);
            frame_crc = c;
        end
    endfunction

    reg [7:0] first_response [0:21];
    reg [7:0] replay_response [0:21];
    reg [7:0] nack_response [0:21];

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // A valid PING reaches the command boundary and can be ACKed.
        send_frame(V2_OP_PING, 8'h00, 8'h07, 32'h00000000, 1'b0);
        accept_command();
        if (cmd_op !== V2_OP_PING || cmd_address !== 0 ||
            cmd_sequence !== 8'h07 || cmd_data !== 0)
            $fatal(1, "PING command fields mismatch");
        respond(8'h07, V2_ACK_ACCEPTED, V2_ERR_NONE, 32'hdeadbeef, 1'b1);
        collect_frame(first_response);
        if (first_response[0] !== V2_TELEMETRY_SOF ||
            first_response[2] !== V2_TLM_ACK || first_response[4] !== 8'h07 ||
            first_response[11] !== V2_ACK_ACCEPTED || first_response[19] !== 0)
            $fatal(1, "ACK fields mismatch");
        if ({first_response[20],first_response[21]} !== frame_crc(first_response))
            $fatal(1, "ACK CRC mismatch");

        // The exact same request must replay the exact cached 22-byte reply.
        send_frame(V2_OP_PING, 8'h00, 8'h07, 32'h00000000, 1'b0);
        collect_frame(replay_response);
        for (i = 0; i < 22; i = i + 1)
            if (replay_response[i] !== first_response[i])
                $fatal(1, "duplicate replay mismatch at byte %0d", i);

        // Reusing a sequence with different bytes is a protocol NACK.
        send_frame(V2_OP_PING, 8'h00, 8'h07, 32'h00000001, 1'b0);
        collect_frame(nack_response);
        if (nack_response[2] !== V2_TLM_NACK || nack_response[19] !== V2_ERR_SEQUENCE)
            $fatal(1, "sequence conflict was not rejected");
        if ({nack_response[20],nack_response[21]} !== frame_crc(nack_response))
            $fatal(1, "sequence NACK CRC mismatch");

        // Bad CRC must report BAD_CRC, not a stale previous protocol_error.
        send_frame(V2_OP_PING, 8'h00, 8'h08, 32'h00000000, 1'b1);
        collect_frame(nack_response);
        if (nack_response[2] !== V2_TLM_NACK || nack_response[19] !== V2_ERR_BAD_CRC)
            $fatal(1, "bad CRC error code mismatch: %h", nack_response[19]);

        // A valid RW address with an out-of-range value is BAD_DATA.
        send_frame(V2_OP_WRITE, V2_CSR_MODE, 8'h0a, 32'h00000007, 1'b0);
        collect_frame(nack_response);
        if (nack_response[2] !== V2_TLM_NACK || nack_response[19] !== V2_ERR_BAD_DATA)
            $fatal(1, "bad data error code mismatch: %h", nack_response[19]);

        // TX backpressure must hold the current byte and frame.
        send_frame(V2_OP_PING, 8'h00, 8'h09, 32'h00000000, 1'b0);
        accept_command();
        respond(8'h09, V2_ACK_APPLIED, V2_ERR_NONE, 32'h01020304, 1'b1);
        while (!tx_valid) @(posedge clk);
        tx_ready = 1'b0;
        repeat (3) begin
            @(posedge clk);
            if (!tx_valid || tx_byte !== V2_TELEMETRY_SOF)
                $fatal(1, "TX byte changed under backpressure");
        end
        tx_ready = 1'b1;
        collect_frame(nack_response);

        $display("tb_v2_uart_link PASS");
        $finish;
    end
endmodule
