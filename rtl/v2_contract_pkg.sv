package v2_contract_pkg;
  localparam logic [7:0] V2_VERSION = 8'h02;
  localparam logic [7:0] V2_CONTROL_SOF = 8'hA5;
  localparam logic [7:0] V2_TELEMETRY_SOF = 8'h5A;
  localparam int V2_EVENT_BITS = 96;
  localparam int V2_CONTROL_BYTES = 11;
  localparam int V2_TELEMETRY_BYTES = 22;

  typedef enum logic [2:0] { IDLE, LIVE, RECORD, COMMIT, PLAY, ERROR } v2_mode_e;

  // Packed MSB-first layout: reserved[95], then the named fields through sequence[15:0].
  // The reserved bit is frozen at zero by serializers; the named fields are directly accessible.
  typedef struct packed {
    logic        reserved;
    logic [3:0]  event_type;
    logic [2:0]  track;
    logic [7:0]  tick;
    logic [7:0]  duration;
    logic [7:0]  note;
    logic [7:0]  velocity;
    logic signed [15:0] pitch_mod;
    logic [15:0] timbre_mod;
    logic [7:0]  flags;
    logic [15:0] event_sequence;
  } v2_event_t;

  typedef struct packed {
    logic [7:0]  op;
    logic [7:0]  address;
    logic [7:0]  event_sequence;
    logic [31:0] data;
  } v2_cmd_t;
  typedef struct packed {
    logic [7:0]  event_type;
    logic [15:0] event_sequence;
    logic signed [15:0] x;
    logic signed [15:0] y;
    logic signed [15:0] z;
    logic [7:0] note;
    logic [7:0] flags;
    logic [7:0] tick;
    logic [31:0] voice_bitmap;
    logic [7:0] fifo_level;
    logic [7:0] fault_code;
  } v2_telemetry_t;

  localparam logic [7:0] V2_ADDR_LEGACY_FIRST = 8'h00;
  localparam logic [7:0] V2_ADDR_LEGACY_LAST  = 8'h44;
  localparam logic [7:0] V2_ADDR_PATCH_FIRST  = 8'h48;
  localparam logic [7:0] V2_ADDR_PATCH_LAST   = 8'h5C;
  localparam logic [7:0] V2_ADDR_WT_FIRST     = 8'h60;
  localparam logic [7:0] V2_ADDR_WT_LAST      = 8'h7C;
  localparam logic [7:0] V2_ADDR_DIAG_FIRST   = 8'h80;
  localparam logic [7:0] V2_ADDR_DIAG_LAST    = 8'h9C;
  localparam logic [7:0] V2_ADDR_TEST_FIRST   = 8'hA0;
  localparam logic [7:0] V2_ADDR_TEST_LAST    = 8'hAF;

  localparam logic [7:0] V2_ERR_NONE = 8'h00;
  localparam logic [7:0] V2_ERR_BAD_CRC = 8'h01;
  localparam logic [7:0] V2_ERR_BAD_ADDRESS = 8'h02;
  localparam logic [7:0] V2_ERR_BAD_VERSION = 8'h03;
  localparam logic [7:0] V2_ERR_BAD_LENGTH = 8'h04;
  localparam logic [7:0] V2_ERR_SEQUENCE = 8'h05;

  function automatic bit v2_address_valid(input logic [7:0] address);
    return ((address >= V2_ADDR_LEGACY_FIRST && address <= V2_ADDR_LEGACY_LAST) ||
            (address >= V2_ADDR_PATCH_FIRST && address <= V2_ADDR_PATCH_LAST) ||
            (address >= V2_ADDR_WT_FIRST && address <= V2_ADDR_WT_LAST) ||
            (address >= V2_ADDR_DIAG_FIRST && address <= V2_ADDR_DIAG_LAST) ||
            (address >= V2_ADDR_TEST_FIRST && address <= V2_ADDR_TEST_LAST));
  endfunction

  // Elaboration-time checks: a violated contract makes an illegal negative-width typedef.
  localparam int V2_EVENT_WIDTH_CHECK = ($bits(v2_event_t) == V2_EVENT_BITS) ? 1 : -1;
  localparam int V2_CMD_WIDTH_CHECK = ($bits(v2_cmd_t) == 56) ? 1 : -1;
  localparam int V2_TELEMETRY_WIDTH_CHECK = ($bits(v2_telemetry_t) == 144) ? 1 : -1;
  localparam int V2_CONTROL_LENGTH_CHECK = (V2_CONTROL_BYTES == 11) ? 1 : -1;
  localparam int V2_TELEMETRY_LENGTH_CHECK = (V2_TELEMETRY_BYTES == 22) ? 1 : -1;
  localparam int V2_ADDRESS_MAP_CHECK =
      (v2_address_valid(8'h00) && v2_address_valid(8'h44) &&
       v2_address_valid(8'h48) && v2_address_valid(8'h5C) &&
       v2_address_valid(8'h60) && v2_address_valid(8'h7C) &&
       v2_address_valid(8'h80) && v2_address_valid(8'h9C) &&
       v2_address_valid(8'hA0) && v2_address_valid(8'hAF) &&
       !v2_address_valid(8'h45) && !v2_address_valid(8'h5D) &&
       !v2_address_valid(8'h7D) && !v2_address_valid(8'h9D) &&
       !v2_address_valid(8'hB0)) ? 1 : -1;
  typedef logic [V2_EVENT_WIDTH_CHECK-1:0] v2_event_width_assert_t;
  typedef logic [V2_CMD_WIDTH_CHECK-1:0] v2_cmd_width_assert_t;
  typedef logic [V2_TELEMETRY_WIDTH_CHECK-1:0] v2_telemetry_width_assert_t;
  typedef logic [V2_CONTROL_LENGTH_CHECK-1:0] v2_control_length_assert_t;
  typedef logic [V2_TELEMETRY_LENGTH_CHECK-1:0] v2_telemetry_length_assert_t;
  typedef logic [V2_ADDRESS_MAP_CHECK-1:0] v2_address_map_assert_t;
endpackage
