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
    for (address = 'hA0; address <= 'hAF; address = address + 1)
      if (v2_csr_access(address[7:0]) != V2_ACCESS_RW ||
          v2_csr_write_mask(address[7:0]) != 32'hFFFFFFFF)
        $fatal(1, "test selector access/mask mismatch at %h", address[7:0]);
    if (!v2_csr_data_valid(V2_CSR_MODE,32'd5) ||
        v2_csr_data_valid(V2_CSR_MODE,32'd6) ||
        v2_csr_data_valid(V2_CSR_TRACK,32'd6) ||
        v2_csr_data_valid(V2_CSR_WT_SELECT,32'd3) ||
        v2_csr_data_valid(V2_CSR_BPM,32'd59) ||
        !v2_csr_data_valid(V2_CSR_BPM,32'd120) ||
        v2_csr_data_valid(V2_CSR_PATCH_SELECT,32'h00000007) ||
        !v2_csr_data_valid(V2_CSR_PATCH_SELECT,32'h0000001D) ||
        v2_csr_data_valid(V2_CSR_TRACK,32'h00000008))
      $fatal(1, "CSR semantic validation mismatch");
    if (v2_csr_access(V2_CSR_STATUS) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_STATUS) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: STATUS");
    if (v2_csr_access(V2_CSR_MODE) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_MODE) != 32'h00000007)
      $fatal(1, "CSR access/mask mismatch: MODE");
    if (v2_csr_access(V2_CSR_BPM) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_BPM) != 32'h0000FFFF)
      $fatal(1, "CSR access/mask mismatch: BPM");
    if (v2_csr_access(V2_CSR_TRACK) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_TRACK) != 32'h00000007)
      $fatal(1, "CSR access/mask mismatch: TRACK");
    if (v2_csr_access(V2_CSR_PLAY) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_PLAY) != 32'h00000001)
      $fatal(1, "CSR access/mask mismatch: PLAY");
    if (v2_csr_access(V2_CSR_STOP) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_STOP) != 32'h00000001)
      $fatal(1, "CSR access/mask mismatch: STOP");
    if (v2_csr_access(V2_CSR_RECORD) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_RECORD) != 32'h00000001)
      $fatal(1, "CSR access/mask mismatch: RECORD");
    if (v2_csr_access(V2_CSR_OVERDUB) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_OVERDUB) != 32'h00000001)
      $fatal(1, "CSR access/mask mismatch: OVERDUB");
    if (v2_csr_access(V2_CSR_CLEAR_TRACK) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_CLEAR_TRACK) != 32'h00000107)
      $fatal(1, "CSR access/mask mismatch: CLEAR_TRACK");
    if (v2_csr_access(V2_CSR_CLEAR_ALL) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_CLEAR_ALL) != 32'h00000001)
      $fatal(1, "CSR access/mask mismatch: CLEAR_ALL");
    if (v2_csr_access(V2_CSR_COMMIT) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_COMMIT) != 32'h00000001)
      $fatal(1, "CSR access/mask mismatch: COMMIT");
    if (v2_csr_access(V2_CSR_RESET) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_RESET) != 32'h00000001)
      $fatal(1, "CSR access/mask mismatch: RESET");
    if (v2_csr_access(V2_CSR_THRESHOLDS) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_THRESHOLDS) != 32'hFFFFFFFF)
      $fatal(1, "CSR access/mask mismatch: THRESHOLDS");
    if (v2_csr_access(V2_CSR_POSITION) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_POSITION) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: POSITION");
    if (v2_csr_access(V2_CSR_FAULT) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_FAULT) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: FAULT");
    if (v2_csr_access(V2_CSR_DIAG_INPUT) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_DIAG_INPUT) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: DIAG_INPUT");
    if (v2_csr_access(V2_CSR_DIAG_AUDIO) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_DIAG_AUDIO) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: DIAG_AUDIO");
    if (v2_csr_access(V2_CSR_DIAG_ROUTER) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_DIAG_ROUTER) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: DIAG_ROUTER");
    if (v2_csr_access(V2_CSR_PATCH_SELECT) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_PATCH_SELECT) != 32'h0000FF1F)
      $fatal(1, "CSR access/mask mismatch: PATCH_SELECT");
    if (v2_csr_access(V2_CSR_PATCH_SHADOW_DATA) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_PATCH_SHADOW_DATA) != 32'hFFFFFFFF)
      $fatal(1, "CSR access/mask mismatch: PATCH_SHADOW_DATA");
    if (v2_csr_access(V2_CSR_PATCH_ACTIVE_DATA) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_PATCH_ACTIVE_DATA) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: PATCH_ACTIVE_DATA");
    if (v2_csr_access(V2_CSR_PATCH_STATUS) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_PATCH_STATUS) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: PATCH_STATUS");
    if (v2_csr_access(V2_CSR_PATCH_CRC) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_PATCH_CRC) != 32'h0000FFFF)
      $fatal(1, "CSR access/mask mismatch: PATCH_CRC");
    if (v2_csr_access(V2_CSR_PATCH_APPLY) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_PATCH_APPLY) != 32'h8000FFFF)
      $fatal(1, "CSR access/mask mismatch: PATCH_APPLY");
    if (v2_csr_access(V2_CSR_WT_SELECT) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_WT_SELECT) != 32'h00000107)
      $fatal(1, "CSR access/mask mismatch: WT_SELECT");
    if (v2_csr_access(V2_CSR_WT_INDEX) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_WT_INDEX) != 32'h0000FFFF)
      $fatal(1, "CSR access/mask mismatch: WT_INDEX");
    if (v2_csr_access(V2_CSR_WT_DATA) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_WT_DATA) != 32'h0000FFFF)
      $fatal(1, "CSR access/mask mismatch: WT_DATA");
    if (v2_csr_access(V2_CSR_WT_LENGTH) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_WT_LENGTH) != 32'h0000FFFF)
      $fatal(1, "CSR access/mask mismatch: WT_LENGTH");
    if (v2_csr_access(V2_CSR_WT_CRC) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_WT_CRC) != 32'h0000FFFF)
      $fatal(1, "CSR access/mask mismatch: WT_CRC");
    if (v2_csr_access(V2_CSR_WT_VERSION) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_WT_VERSION) != 32'h0000FFFF)
      $fatal(1, "CSR access/mask mismatch: WT_VERSION");
    if (v2_csr_access(V2_CSR_WT_APPLY) != V2_ACCESS_WO ||
        v2_csr_write_mask(V2_CSR_WT_APPLY) != 32'h8000FFFF)
      $fatal(1, "CSR access/mask mismatch: WT_APPLY");
    if (v2_csr_access(V2_CSR_WT_STATUS) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_WT_STATUS) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: WT_STATUS");
    if (v2_csr_access(V2_CSR_TLM_CONTROL) != V2_ACCESS_RW ||
        v2_csr_write_mask(V2_CSR_TLM_CONTROL) != 32'hFFFF0001)
      $fatal(1, "CSR access/mask mismatch: TLM_CONTROL");
    if (v2_csr_access(V2_CSR_TLM_STATUS) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_TLM_STATUS) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: TLM_STATUS");
    if (v2_csr_access(V2_CSR_TLM_LATENCY) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_TLM_LATENCY) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: TLM_LATENCY");
    if (v2_csr_access(V2_CSR_TLM_PEAK) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_TLM_PEAK) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: TLM_PEAK");
    if (v2_csr_access(V2_CSR_TLM_RMS) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_TLM_RMS) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: TLM_RMS");
    if (v2_csr_access(V2_CSR_TLM_FIFO) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_TLM_FIFO) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: TLM_FIFO");
    if (v2_csr_access(V2_CSR_TLM_FAULT) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_TLM_FAULT) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: TLM_FAULT");
    if (v2_csr_access(V2_CSR_TLM_TABLE_VERSION) != V2_ACCESS_RO ||
        v2_csr_write_mask(V2_CSR_TLM_TABLE_VERSION) != 32'h00000000)
      $fatal(1, "CSR access/mask mismatch: TLM_TABLE_VERSION");
    $display("V2 contract PASS");
    $finish;
  end
endmodule
