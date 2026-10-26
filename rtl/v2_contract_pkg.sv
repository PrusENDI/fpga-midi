package v2_contract_pkg;
  localparam logic [7:0] V2_VERSION = 8'h02;
  localparam logic [7:0] V2_CONTROL_SOF = 8'hA5;
  localparam logic [7:0] V2_TELEMETRY_SOF = 8'h5A;
  localparam int V2_EVENT_BITS = 96;
  localparam int V2_CONTROL_BYTES = 11;
  localparam int V2_TELEMETRY_BYTES = 22;

  typedef enum logic [2:0] { IDLE, LIVE, RECORD, COMMIT, PLAY, ERROR } v2_mode_e;

  // The leading reserved bit is explicit so the ten specified fields occupy 95 bits.
  typedef logic [95:0] v2_event_t;
  typedef struct packed {
    logic [7:0]  op;
    logic [7:0]  address;
    logic [7:0]  sequence;
    logic [31:0] data;
  } v2_cmd_t;
  typedef struct packed {
    logic [7:0]  type;
    logic [15:0] sequence;
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

  function automatic bit v2_contract_widths_ok();
    return ($bits(v2_event_t) == 96 && $bits(v2_cmd_t) == 56 && $bits(v2_telemetry_t) == 136);
  endfunction
endpackage
