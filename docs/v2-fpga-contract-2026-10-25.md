# V2 FPGA contract (frozen 2026-10-25)

This document is the single source of truth for the V2 wire and type contract. V1
`control_protocol_pkg`, `performance_event_pkg`, and the legacy top remain unchanged.
Only `v2_uart_link.sv` listens to V2 `uart_rx`; the old top is not connected to V2 UART.

## Modes

`IDLE`, `LIVE`, `RECORD`, `COMMIT`, `PLAY`, and `ERROR` are the only V2 modes.

## Event (96 bits / 12 bytes)

Fields are serialized most significant bit first. Bit 95 is reserved and must be zero,
followed by `type[3:0]`, `track[2:0]`, `tick[7:0]`, `duration[7:0]`, `note[7:0]`,
`velocity[7:0]`, `pitch_mod[15:0]`, `timbre_mod[15:0]`, `flags[7:0]`, and
`sequence[15:0]`. `pitch_mod` is signed two's complement; all other listed fields are
unsigned unless stated otherwise.

Event type values: 1 NOTE_ON, 2 NOTE_OFF, 3 REVOICE, 4 CONTROL, 5 ALL_NOTES_OFF,
6 BOUNDARY. Value 0 is invalid. Flag bits: 0 TOUCH, 1 BOW, 2 Z, 3 REBASED,
4 DEGRADED, 5 GAP; bits 6–7 reserved zero. Existing Task5 values 1–4 and
flags 0–3 are preserved. Fault codes: 0 NONE, 1 INVALID, 2 REVERSE, 3 FIFO,
4 TICK, 5 OVERFLOW, 6 ABORT. UART errors use a separate namespace.

## Control packet (11 bytes)

`A5 02 op address sequence data[31:24] data[23:16] data[15:8] data[7:0] crc[15:8] crc[7:0]`.
All multi-byte values are big endian. CRC is CRC-16/CCITT-FALSE (polynomial `0x1021`,
initial `0xFFFF`) over the first nine bytes. Addresses outside the ranges below are
rejected.

`op`: 1 READ, 2 WRITE, 3 PING. READ returns an atomic CSR snapshot. WRITE is
accepted only for RW/WO registers; PING requires address `0x00` and data zero.
`sequence` is an 8-bit transaction ID. A duplicate sequence with identical bytes
replays the prior reply without reapplying a write; same sequence with different
bytes is NACK/SEQUENCE. Host advances sequence modulo 256 only after reply.
Response telemetry types are `0x80` ACK and `0x81` NACK; `note` carries ACK status
(0 ACCEPTED, 1 APPLIED, 2 REJECTED, 3 BUSY, 4 ERROR), `fault_code` carries error
(0 NONE, 1 BAD_CRC, 2 BAD_ADDRESS, 3 BAD_VERSION, 4 BAD_LENGTH, 5 SEQUENCE),
`sequence[7:0]` echoes request sequence, and READ result is `voice_bitmap[31:0]`.
Other response fields are zero. Normal response timeout is 1000 ms; operations
waiting on a Loop boundary may take 34000 ms. A timeout requires readback before
retrying a non-idempotent write.

| Range | Region |
| --- | --- |
| `0x00–0x44` | legacy Loop |
| `0x48–0x5C` | patch/gesture |
| `0x60–0x7C` | wavetable/APPLY |
| `0x80–0x9C` | telemetry/diagnostics |
| `0xA0–0xAF` | test mode |

Except the sixteen indexed test selectors `0xA0–0xAF`, valid CSR addresses are
32-bit word aligned. Unassigned bytes inside each range are rejected. The full
register list below defines R/W and packing; unspecified bits read zero and
must be written zero. RO writes and WO reads are NACK/BAD_ADDRESS.

Patch and wavetable writes update shadow state. `PATCH_APPLY` and `WT_APPLY`
require bit 31 and an expected version in bits 15:0; the latter additionally
requires a complete table, matching `WT_CRC` (CRC-16/CCITT-FALSE over big-endian
signed 16-bit sample bytes), and matching `WT_LENGTH`. Only a successful APPLY
atomically swaps active/shadow at a sample boundary and increments active version
modulo 65536. Version mismatch, bad CRC, or incomplete shadow returns NACK/ERROR
without altering active state. `WT_STATUS` reports shadow validity, busy and
the last error. STOP aborts pending APPLY and silences voices.

## Telemetry packet (22 bytes)

`5A 02 type sequence[15:8] sequence[7:0] x[15:8] x[7:0] y[15:8] y[7:0] z[15:8] z[7:0] note flags tick voice_bitmap[31:24] ... voice_bitmap[7:0] fifo_level fault_code crc[15:8] crc[7:0]`.
The body is 20 bytes; CRC-16/CCITT-FALSE covers the body. `x`, `y`, and `z` are
signed two's-complement 16-bit values. `voice_bitmap` is 32 bits; `fifo_level` and
`fault_code` are 8 bits.

Telemetry type 1 SNAPSHOT uses the layout above. Type 2 STATS reuses the same
22-byte frame: `x/y/z` are signed cursor values, `voice_bitmap` is latency in
microseconds, `note` is peak Q0.8, `flags` is RMS Q0.8, `tick` is FX level,
`fifo_level` and `fault_code` retain their meanings. Type 3 TABLE uses
`voice_bitmap[15:0]` for active table version and `[31:16]` for shadow version;
other fields retain SNAPSHOT meaning. No type changes the header, CRC coverage,
or frame length.

## Raw input coordinate boundary (integration pending)

MGC3130 raw X/Y/Z are unsigned 16-bit values (`0..65535`). At the input latch,
store them in signed 17-bit arithmetic containers: X/Y subtract 32768 to map to
`-32768..32767`; Z is zero extended and remains `0..65535`. Calibration arithmetic
must sign extend X/Y and zero extend Z before signed operations. This preserves
the Z release threshold 36000. The 16-bit signed telemetry XYZ fields are
*normalized display coordinates*: X/Y use centered values; Z transmits
`clamp(raw_Z - 32768, -32768, 32767)`, so a receiver reconstructs raw Z by
adding 32768. Task3/Task4 integration has not been verified against this boundary;
the current direct signed cast is a known mismatch to fix and test there.

## Implementation invariants

There is one V2 event layout, one control packet length, one telemetry packet length,
and one CSR address map. Any new RTL must import `v2_contract_pkg` and use these constants.

## CSR register definitions

| CSR | Address | Access | 32-bit data packing |
| --- | --- | --- | --- |
| STATUS | 0x00 | RO | mode[2:0],active_valid[8],fault[9] |
| MODE | 0x04 | RW | mode[2:0] |
| BPM | 0x08 | RW | active_bpm[31:16],shadow_bpm[15:0] |
| TRACK | 0x0C | RW | track[2:0] |
| PLAY | 0x10 | WO | trigger[0] |
| STOP | 0x14 | WO | trigger[0] |
| RECORD | 0x18 | WO | trigger[0] |
| OVERDUB | 0x1C | WO | trigger[0] |
| CLEAR_TRACK | 0x20 | WO | track[2:0],trigger[8] |
| CLEAR_ALL | 0x24 | WO | trigger[0] |
| COMMIT | 0x28 | WO | trigger[0] |
| RESET | 0x2C | WO | trigger[0] |
| THRESHOLDS | 0x30 | RW | release[31:16],engage[15:0] |
| POSITION | 0x34 | RO | tick[7:0],active_valid[8],commit_pending[9],fault[10] |
| FAULT | 0x38 | RO | fault_code[7:0],sticky[8] |
| DIAG_INPUT | 0x3C | RO | invalid_count[15:0],gap_count[31:16] |
| DIAG_AUDIO | 0x40 | RO | underrun_count[15:0],peak_q15[31:16] |
| DIAG_ROUTER | 0x44 | RO | drop_count[15:0],fifo_level[23:16] |
| PATCH_SELECT | 0x48 | RW | patch_id[7:0],track[10:8] |
| PATCH_GAIN | 0x4C | RW | gain_q16_16[31:0] |
| PATCH_BRIGHTNESS | 0x50 | RW | brightness_q16_16[31:0] |
| GESTURE | 0x54 | RW | touch_threshold[15:0],bow_threshold[31:16] |
| FX | 0x58 | RW | fx_level[7:0],mix_q8[15:8],feedback_q8[23:16] |
| PATCH_APPLY | 0x5C | WO | expected_version[15:0],trigger[31] |
| WT_SELECT | 0x60 | RW | table_id[7:0],bank[8] |
| WT_INDEX | 0x64 | RW | sample_index[15:0] |
| WT_DATA | 0x68 | RW | sample_s16[15:0] |
| WT_LENGTH | 0x6C | RW | sample_count[15:0] |
| WT_CRC | 0x70 | RW | crc16_ccitt[15:0] |
| WT_VERSION | 0x74 | RW | expected_version[15:0] |
| WT_APPLY | 0x78 | WO | expected_version[15:0],trigger[31] |
| WT_STATUS | 0x7C | RO | active_version[15:0],shadow_valid[16],apply_busy[17],last_error[31:24] |
| TLM_CONTROL | 0x80 | RW | enable[0],period_ms[31:16] |
| TLM_STATUS | 0x84 | RO | last_type[7:0],sequence[23:8] |
| TLM_LATENCY | 0x88 | RO | latency_us[31:0] |
| TLM_PEAK | 0x8C | RO | peak_q15[15:0] |
| TLM_RMS | 0x90 | RO | rms_q15[15:0] |
| TLM_FIFO | 0x94 | RO | rx_level[7:0],tx_level[15:8],event_level[23:16] |
| TLM_FAULT | 0x98 | RO | fault_code[7:0],fault_count[31:8] |
| TLM_TABLE_VERSION | 0x9C | RO | active_version[15:0],shadow_version[31:16] |
| TEST_SELECT_0..F | 0xA0..0xAF | RW | selector[7:0],value[31:8]; selector index is low address nibble |
