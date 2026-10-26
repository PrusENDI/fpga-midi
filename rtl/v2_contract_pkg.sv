package v2_contract_pkg;
  localparam logic [7:0] V2_VERSION = 8'h02;
  localparam logic [7:0] V2_CONTROL_SOF = 8'hA5;
  localparam logic [7:0] V2_TELEMETRY_SOF = 8'h5A;
  localparam int V2_EVENT_BITS = 96;
  localparam int V2_CONTROL_BYTES = 11;
  localparam int V2_TELEMETRY_BYTES = 22;
  localparam logic [3:0] V2_EV_NOTE_ON=4'd1, V2_EV_NOTE_OFF=4'd2,
      V2_EV_REVOICE=4'd3, V2_EV_CONTROL=4'd4, V2_EV_ALL_NOTES_OFF=4'd5,
      V2_EV_BOUNDARY=4'd6;
  localparam logic [7:0] V2_FLAG_TOUCH=8'h01, V2_FLAG_BOW=8'h02,
      V2_FLAG_Z=8'h04, V2_FLAG_REBASED=8'h08,
      V2_FLAG_DEGRADED=8'h10, V2_FLAG_GAP=8'h20;
  localparam logic [7:0] V2_FAULT_NONE=8'd0, V2_FAULT_INVALID=8'd1,
      V2_FAULT_REVERSE=8'd2, V2_FAULT_FIFO=8'd3, V2_FAULT_TICK=8'd4,
      V2_FAULT_OVERFLOW=8'd5, V2_FAULT_ABORT=8'd6;
  localparam logic [7:0] V2_OP_READ=8'h01, V2_OP_WRITE=8'h02,
      V2_OP_PING=8'h03;
  localparam logic [7:0] V2_ACK_ACCEPTED=8'd0, V2_ACK_APPLIED=8'd1,
      V2_ACK_REJECTED=8'd2, V2_ACK_BUSY=8'd3, V2_ACK_ERROR=8'd4;
  localparam logic [7:0] V2_TLM_SNAPSHOT=8'h01,
      V2_TLM_STATS=8'h02, V2_TLM_TABLE=8'h03,
      V2_TLM_ACK=8'h80, V2_TLM_NACK=8'h81;
  localparam int V2_RESPONSE_TIMEOUT_MS=1000;
  localparam int V2_BOUNDARY_TIMEOUT_MS=34000;

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

  // Word register offsets; A0..AF are sixteen indexed test selectors.
  localparam logic [7:0] V2_CSR_STATUS=8'h00, V2_CSR_MODE=8'h04,
      V2_CSR_BPM=8'h08, V2_CSR_TRACK=8'h0C, V2_CSR_PLAY=8'h10,
      V2_CSR_STOP=8'h14, V2_CSR_RECORD=8'h18, V2_CSR_OVERDUB=8'h1C,
      V2_CSR_CLEAR_TRACK=8'h20, V2_CSR_CLEAR_ALL=8'h24,
      V2_CSR_COMMIT=8'h28, V2_CSR_RESET=8'h2C,
      V2_CSR_THRESHOLDS=8'h30, V2_CSR_POSITION=8'h34,
      V2_CSR_FAULT=8'h38, V2_CSR_DIAG_INPUT=8'h3C,
      V2_CSR_DIAG_AUDIO=8'h40, V2_CSR_DIAG_ROUTER=8'h44;
  localparam logic [7:0] V2_CSR_PATCH_SELECT=8'h48,
      V2_CSR_PATCH_GAIN=8'h4C, V2_CSR_PATCH_BRIGHTNESS=8'h50,
      V2_CSR_GESTURE=8'h54, V2_CSR_FX=8'h58,
      V2_CSR_PATCH_APPLY=8'h5C;
  localparam logic [7:0] V2_CSR_WT_SELECT=8'h60,
      V2_CSR_WT_INDEX=8'h64, V2_CSR_WT_DATA=8'h68,
      V2_CSR_WT_LENGTH=8'h6C, V2_CSR_WT_CRC=8'h70,
      V2_CSR_WT_VERSION=8'h74, V2_CSR_WT_APPLY=8'h78,
      V2_CSR_WT_STATUS=8'h7C;
  localparam logic [7:0] V2_CSR_TLM_CONTROL=8'h80,
      V2_CSR_TLM_STATUS=8'h84, V2_CSR_TLM_LATENCY=8'h88,
      V2_CSR_TLM_PEAK=8'h8C, V2_CSR_TLM_RMS=8'h90,
      V2_CSR_TLM_FIFO=8'h94, V2_CSR_TLM_FAULT=8'h98,
      V2_CSR_TLM_TABLE_VERSION=8'h9C;
  localparam logic [7:0] V2_CSR_TEST_SELECT=8'hA0;
  localparam logic [1:0] V2_ACCESS_NONE=2'd0, V2_ACCESS_RO=2'd1,
      V2_ACCESS_WO=2'd2, V2_ACCESS_RW=2'd3;

  localparam logic [7:0] V2_ERR_NONE = 8'h00;
  localparam logic [7:0] V2_ERR_BAD_CRC = 8'h01;
  localparam logic [7:0] V2_ERR_BAD_ADDRESS = 8'h02;
  localparam logic [7:0] V2_ERR_BAD_VERSION = 8'h03;
  localparam logic [7:0] V2_ERR_BAD_LENGTH = 8'h04;
  localparam logic [7:0] V2_ERR_SEQUENCE = 8'h05;

  function automatic bit v2_address_valid(input logic [7:0] address);
    return ((address >= V2_ADDR_TEST_FIRST && address <= V2_ADDR_TEST_LAST) ||
            ((address[1:0] == 2'b00) &&
            ((address >= V2_ADDR_LEGACY_FIRST && address <= V2_ADDR_LEGACY_LAST) ||
            (address >= V2_ADDR_PATCH_FIRST && address <= V2_ADDR_PATCH_LAST) ||
            (address >= V2_ADDR_WT_FIRST && address <= V2_ADDR_WT_LAST) ||
            (address >= V2_ADDR_DIAG_FIRST && address <= V2_ADDR_DIAG_LAST))));
  endfunction
  function automatic logic [1:0] v2_csr_access(input logic [7:0] address);
    if (address >= 8'hA0 && address <= 8'hAF) return V2_ACCESS_RW;
    if (address[1:0] != 2'b00 || !v2_address_valid(address)) return V2_ACCESS_NONE;
    case (address)
      V2_CSR_STATUS, V2_CSR_POSITION, V2_CSR_FAULT,
      V2_CSR_DIAG_INPUT, V2_CSR_DIAG_AUDIO, V2_CSR_DIAG_ROUTER,
      V2_CSR_WT_STATUS, V2_CSR_TLM_STATUS, V2_CSR_TLM_LATENCY,
      V2_CSR_TLM_PEAK, V2_CSR_TLM_RMS, V2_CSR_TLM_FIFO,
      V2_CSR_TLM_FAULT, V2_CSR_TLM_TABLE_VERSION: return V2_ACCESS_RO;
      V2_CSR_PLAY, V2_CSR_STOP, V2_CSR_RECORD, V2_CSR_OVERDUB,
      V2_CSR_CLEAR_TRACK, V2_CSR_CLEAR_ALL, V2_CSR_COMMIT,
      V2_CSR_RESET, V2_CSR_PATCH_APPLY, V2_CSR_WT_APPLY: return V2_ACCESS_WO;
      default: return V2_ACCESS_RW;
    endcase
  endfunction
endpackage
