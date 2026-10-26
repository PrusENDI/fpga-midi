module tb_v2_contract;
  import v2_contract_pkg::*;
  v2_event_t event_word;
  logic [95:0] raw;
  integer address;
  bit expected_address;
  initial begin
    if ($bits(v2_event_t) != 96 || $bits(v2_cmd_t) != 56 ||
        $bits(v2_telemetry_t) != 144) $fatal(1, "type width mismatch");
    if (V2_CONTROL_BYTES != 11 || V2_TELEMETRY_BYTES != 22)
      $fatal(1, "wire length mismatch");
    event_word = '0;
    event_word.event_type = V2_EV_NOTE_ON;
    event_word.track = 3'd5;
    event_word.tick = 8'h12;
    event_word.duration = 8'h34;
    event_word.note = 8'h56;
    event_word.velocity = 8'h78;
    event_word.pitch_mod = -16'sd2;
    event_word.timbre_mod = 16'h1234;
    event_word.flags = V2_FLAG_TOUCH;
    event_word.event_sequence = 16'hBCDE;
    raw = event_word;
    if (raw !== {1'b0, 4'd1, 3'd5, 8'h12, 8'h34, 8'h56, 8'h78,
                 16'hFFFE, 16'h1234, 8'h01, 16'hBCDE})
      $fatal(1, "event field layout mismatch");
    for (address = 0; address < 256; address = address + 1) begin
      expected_address = ((address >= 'hA0 && address <= 'hAF) ||
          ((address % 4 == 0) &&
           ((address <= 'h44) || (address >= 'h48 && address <= 'h5C) ||
            (address >= 'h60 && address <= 'h7C) ||
            (address >= 'h80 && address <= 'h9C))));
      if (v2_address_valid(address[7:0]) !== expected_address)
        $fatal(1, "address map mismatch at %h", address[7:0]);
    end
    if (v2_csr_access(V2_CSR_STATUS) != V2_ACCESS_RO ||
        v2_csr_access(V2_CSR_WT_APPLY) != V2_ACCESS_WO ||
        v2_csr_access(V2_CSR_WT_DATA) != V2_ACCESS_RW ||
        v2_csr_access(8'h49) != V2_ACCESS_NONE)
      $fatal(1, "CSR access mismatch");
    if ($test$plusargs("MUTATE_LAYOUT")) begin
      raw[95] = 1'b1;
      if (raw !== {1'b0, 4'd1, 3'd5, 8'h12, 8'h34, 8'h56, 8'h78,
                   16'hFFFE, 16'h1234, 8'h01, 16'hBCDE})
        $fatal(1, "mutation detected: reserved bit/layout mismatch");
    end
    $display("V2 contract PASS");
    $finish;
  end
endmodule
