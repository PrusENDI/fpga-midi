# V2 FPGA contract (frozen 2026-10-25)

This document is the single source of truth for the V2 wire and type contract. V1
`control_protocol_pkg`, `performance_event_pkg`, and the legacy top remain unchanged.
Only `v2_uart_link.sv` listens to V2 `uart_rx`; the old top is not connected to V2 UART.

## Modes

`IDLE`, `LIVE`, `RECORD`, `COMMIT`, `PLAY`, and `ERROR` are the only V2 modes.
Values 6–7 are invalid. A V2 Loop is 128 ticks, four ticks per beat. BPM is
60–240 inclusive, default 120; at 60 BPM one Loop is 32 seconds, within the
34-second boundary timeout.

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
`sequence` is an 8-bit transaction ID. The receiver caches exactly the most recent
accepted request bytes and its reply. A duplicate sequence with identical bytes
replays that reply without reapplying a write; the same sequence with different
bytes is NACK/SEQUENCE. A new request replaces the single cache entry. The host
advances sequence modulo 256 only after a terminal reply; after 255, zero is a
new transaction if the immediately preceding cached sequence was 255.
Response telemetry types are `0x80` ACK and `0x81` NACK; `note` carries ACK status
(0 ACCEPTED, 1 APPLIED, 2 REJECTED, 3 BUSY, 4 ERROR, 5 SHADOW_STORED,
6 APPLY_ACCEPTED), `fault_code` carries error (0 NONE, 1 BAD_CRC,
2 BAD_ADDRESS, 3 BAD_VERSION, 4 BAD_LENGTH, 5 SEQUENCE, 6 BAD_OP,
7 BAD_DATA, 8 VERSION, 9 INCOMPLETE, 10 WT_CRC, 11 OVERFLOW, 12 TIMEOUT).
`sequence[15:8]` is zero and `[7:0]` echoes request sequence if byte 4 was
received. If framing fails before byte 4, response sequence is `0xFFFF`.
READ result is `voice_bitmap[31:0]`; other response fields are zero. Normal
response timeout is 1000 ms; queued APPLY may wait 34000 ms for a Loop boundary.
APPLY first returns ACK/APPLY_ACCEPTED after validation and queueing. During the
wait, STATUS reports `apply_busy`; at idle or the next Loop boundary the receiver
sends terminal ACK/APPLIED or NACK/error with the same sequence, replacing the
cached interim reply. Duplicate pending requests replay APPLY_ACCEPTED. Timeout
or STOP aborts the queued APPLY; host reads status before retrying a write.

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

`PATCH_SELECT` chooses family[1:0], track[4:2], parameter index[15:8]. Families
0 PATCH and 2 RULE use tracks 0–5; families 1 CALIBRATION and 3 CURSOR require
track 7 (global). `PATCH_SHADOW_DATA` reads/writes the selected 32-bit shadow
value; `PATCH_ACTIVE_DATA` reads the corresponding active value. The selector
itself is immediate, not staged. `PATCH_STATUS` and `PATCH_CRC` refer to the
selected family/track bank. Parameter values must be inside the table limits
below; illegal family/track/index/value returns BAD_DATA. `THRESHOLDS` is a
legacy alias for CURSOR Z_RELEASE[31:16] and Z_ENGAGE[15:0] in the same shadow
bank; no second threshold state exists.

Each PATCH/CALIBRATION/RULE/CURSOR family/track bank has a 16-bit active version.
`PATCH_CRC` holds CRC-16/CCITT-FALSE over *all* shadow values of that bank in
ascending parameter index, each as big-endian 32-bit two's-complement data.
`PATCH_APPLY` requires bit 31 and expected active version in bits 15:0, complete
valid parameters, and matching CRC. A valid APPLY queues an atomic active/shadow
swap at idle or the next Loop boundary, then increments active version modulo
65536. CRC/version/incomplete failures preserve active values. Defaults in the
table initialize both banks and make the initial shadow complete. A subsequent
write marks the bank dirty until CRC is updated and APPLY succeeds.

Wavetable IDs are A=0, B=1, C=2; 3–7 are BAD_DATA. Each table contains exactly
1024 signed 16-bit samples. `WT_SELECT` packs `table_id[2:0]`, `bank[8]`,
`band[11:9]`, and `octave[15:12]`; bits 3–7 and 16–31 are reserved and must be
zero. `bank=0` selects active readback only;
`bank=1` selects shadow upload/readback. `WT_INDEX` chooses 0–1023. Every
`WT_DATA` write stores the low signed 16-bit sample at that index and then
increments the index modulo 1024. Coverage is tracked per index: rewriting one
index never fills a missing index. Upload blocks contain 32 samples: block `b`
(0–31) starts with `WT_INDEX=b*32` followed by 32 `WT_DATA` writes. Repeating a
block is allowed and does not fill other missing indices. `WT_LENGTH` must be
1024. `WT_CRC` is CRC-16/CCITT-FALSE over all 1024 shadow samples in index order,
each big endian.
`WT_VERSION` holds expected active version, and `WT_APPLY` bits 15:0 must match
both `WT_VERSION` and current active version, with bit 31 set. A complete,
CRC-valid upload queues atomic swap at idle or next Loop boundary and increments
active version modulo 65536. Any mismatch preserves active. `WT_STATUS` exposes
valid/busy/error. A 6/7 MODE value, track 6/7, invalid selector, invalid WT ID,
out-of-range BPM, or reserved write bit is BAD_DATA. RO write/WO read is
BAD_ADDRESS; unknown op is BAD_OP.

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

Legacy addresses 0x00–0x44 retain their V1 names and offsets; V2 TRACK is three bits for six tracks. The write mask and per-field shifts are also exported as `V2_CSR_*_WRITE_MASK` and `V2_CSR_*_*_SHIFT` in the SV/Python contract.

| CSR | Address | Access | 32-bit data packing | Write mask |
| --- | --- | --- | --- | --- |
| STATUS | 0x00 | RO | mode[2:0],active_valid[8],fault[9] | 0x00000000 |
| MODE | 0x04 | RW | mode[2:0] | 0x00000007 |
| BPM | 0x08 | RW | active_bpm[31:16],shadow_bpm[15:0] | 0x0000FFFF |
| TRACK | 0x0C | RW | track[2:0] | 0x00000007 |
| PLAY | 0x10 | WO | trigger[0] | 0x00000001 |
| STOP | 0x14 | WO | trigger[0] | 0x00000001 |
| RECORD | 0x18 | WO | trigger[0] | 0x00000001 |
| OVERDUB | 0x1C | WO | trigger[0] | 0x00000001 |
| CLEAR_TRACK | 0x20 | WO | track[2:0],trigger[8] | 0x00000107 |
| CLEAR_ALL | 0x24 | WO | trigger[0] | 0x00000001 |
| COMMIT | 0x28 | WO | trigger[0] | 0x00000001 |
| RESET | 0x2C | WO | trigger[0] | 0x00000001 |
| THRESHOLDS | 0x30 | RW | release[31:16],engage[15:0] | 0xFFFFFFFF |
| POSITION | 0x34 | RO | tick[7:0],active_valid[8],commit_pending[9],fault[10] | 0x00000000 |
| FAULT | 0x38 | RO | fault_code[7:0],sticky[8] | 0x00000000 |
| DIAG_INPUT | 0x3C | RO | invalid_count[15:0],gap_count[31:16] | 0x00000000 |
| DIAG_AUDIO | 0x40 | RO | underrun_count[15:0],peak_q15[31:16] | 0x00000000 |
| DIAG_ROUTER | 0x44 | RO | drop_count[15:0],fifo_level[23:16] | 0x00000000 |
| PATCH_SELECT | 0x48 | RW | family[1:0],track[4:2],index[15:8] | 0x0000FF1F |
| PATCH_SHADOW_DATA | 0x4C | RW | value[31:0] | 0xFFFFFFFF |
| PATCH_ACTIVE_DATA | 0x50 | RO | value[31:0] | 0x00000000 |
| PATCH_STATUS | 0x54 | RO | active_version[15:0],shadow_dirty[16],crc_ok[17],apply_busy[18],last_error[31:24] | 0x00000000 |
| PATCH_CRC | 0x58 | RW | crc16_ccitt[15:0] | 0x0000FFFF |
| PATCH_APPLY | 0x5C | WO | expected_version[15:0],trigger[31] | 0x8000FFFF |
| WT_SELECT | 0x60 | RW | table_id[2:0],bank[8],band[11:9],octave[15:12] | 0x0000FF07 |
| WT_INDEX | 0x64 | RW | sample_index[15:0] | 0x0000FFFF |
| WT_DATA | 0x68 | RW | sample_s16[15:0] | 0x0000FFFF |
| WT_LENGTH | 0x6C | RW | sample_count[15:0] | 0x0000FFFF |
| WT_CRC | 0x70 | RW | crc16_ccitt[15:0] | 0x0000FFFF |
| WT_VERSION | 0x74 | RW | expected_version[15:0] | 0x0000FFFF |
| WT_APPLY | 0x78 | WO | expected_version[15:0],trigger[31] | 0x8000FFFF |
| WT_STATUS | 0x7C | RO | active_version[15:0],shadow_valid[16],apply_busy[17],last_error[31:24] | 0x00000000 |
| TLM_CONTROL | 0x80 | RW | enable[0],period_ms[31:16] | 0xFFFF0001 |
| TLM_STATUS | 0x84 | RO | last_type[7:0],sequence[23:8] | 0x00000000 |
| TLM_LATENCY | 0x88 | RO | latency_us[31:0] | 0x00000000 |
| TLM_PEAK | 0x8C | RO | peak_q15[15:0] | 0x00000000 |
| TLM_RMS | 0x90 | RO | rms_q15[15:0] | 0x00000000 |
| TLM_FIFO | 0x94 | RO | rx_level[7:0],tx_level[15:8],event_level[23:16] | 0x00000000 |
| TLM_FAULT | 0x98 | RO | fault_code[7:0],fault_count[31:8] | 0x00000000 |
| TLM_TABLE_VERSION | 0x9C | RO | active_version[15:0],shadow_version[31:16] | 0x00000000 |
| TEST_SELECT_0..F | 0xA0..0xAF | RW | selector[7:0],value[31:8]; address low nibble selects test channel | 0xFFFFFFFF |

## Capacity, test selectors, and voice diagnostics

The loop store has two banks, six tracks, and 32 96-bit event slots per track.
`slot` is five bits and each track event count is six bits; the aggregate capacity
is 192 events per bank. These widths are part of the contract so recorder, store,
copy, scheduler, and telemetry hand-offs cannot silently use a smaller legacy
capacity.

When all 32 voices are occupied, the deterministic voice-steal priority is
released, oldest, lowest velocity, then lowest voice ID. The monotonic allocation
counter is 16 bits and wraps by unsigned comparison. The current voice target is
32 voices with two oscillators per voice.

`TEST_SELECT_0` uses selector `1` for the N-tone test mode. Its count range is
1–32 with a default of 8 tones. Selector `2` is reserved for vibrato readback.
The vibrato diagnostic word uses `phase[15:0]` and signed `delta_cents[31:16]`;
the masks and shifts are exported by both the Python and SystemVerilog contracts.

The standalone `v2_test_mode` implementation accepts selector `1` at
`TEST_SELECT_0` and reads back the same selector with the active count in
`value[31:8]`. A write with count zero is a local stop command that disables
the diagnostic generator and resets its phases; counts above 32 latch the
module fault and leave the prior test state unchanged. Selector `2` remains a
reserved voice-diagnostic readback and is not consumed by the standalone
N-tone module. The test mode does not consume EventTable data or alter the
LIVE/LOOP state machine.

## Indexed parameter definitions

Integer bounds/defaults below are raw 32-bit register values. S formats use two's complement; U formats are unsigned. Q notation gives fractional bits. Family/track/index invalid combinations are BAD_DATA. Six-track parameters have separate values for tracks 0–5; global values use track 7. These values are a frozen interface, not a claim that every downstream RTL block is wired to them.

| Family | Index | Name | Format | Min | Max | Default | Scope |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| 0 | 0 | OSC_MIX | UQ0.16 | 0 | 65535 | 32768 | track |
| 0 | 1 | BRIGHTNESS | UQ0.16 | 0 | 65535 | 32768 | track |
| 0 | 2 | DETUNE_CENTS | SQ8.8 | -307200 | 307200 | 0 | track |
| 0 | 3 | ATTACK_MS | U16 | 0 | 10000 | 35 | track |
| 0 | 4 | DECAY_MS | U16 | 0 | 10000 | 180 | track |
| 0 | 5 | SUSTAIN | UQ1.15 | 0 | 32767 | 23593 | track |
| 0 | 6 | RELEASE_MS | U16 | 0 | 10000 | 520 | track |
| 0 | 7 | GLIDE_MS | U16 | 0 | 2000 | 85 | track |
| 0 | 8 | VIBRATO_HZ | UQ8.8 | 0 | 3840 | 1075 | track |
| 0 | 9 | VIBRATO_CENTS | UQ8.8 | 0 | 25600 | 2816 | track |
| 0 | 10 | Z_GAIN | UQ1.15 | 0 | 32767 | 0 | track |
| 0 | 11 | Z_BRIGHTNESS | UQ1.15 | 0 | 32767 | 0 | track |
| 0 | 12 | Z_SPACE | UQ1.15 | 0 | 32767 | 0 | track |
| 0 | 13 | TRACK_ENABLE | U1 | 0 | 1 | 1 | track |
| 0 | 14 | GAIN | UQ16.16 | 0 | 262144 | 65536 | track |
| 0 | 15 | FX_LEVEL | U8 | 0 | 3 | 0 | track |
| 0 | 16 | FX_CUTOFF_HZ | U16 | 20 | 20000 | 12000 | track |
| 0 | 17 | FX_DELAY_MS | U16 | 0 | 1000 | 0 | track |
| 0 | 18 | FX_FEEDBACK | UQ1.15 | 0 | 31129 | 0 | track |
| 0 | 19 | FX_REVERB_MIX | UQ1.15 | 0 | 32767 | 0 | track |
| 1 | 0 | NEUTRAL_X | S32 | -32768 | 32767 | 0 | global |
| 1 | 1 | NEUTRAL_Y | S32 | -32768 | 32767 | 0 | global |
| 1 | 2 | NEUTRAL_Z | S32 | 0 | 65535 | 0 | global |
| 1 | 3 | COUPLING_X | SQ16.16 | -262144 | 262144 | 0 | global |
| 1 | 4 | COUPLING_Y | SQ16.16 | -262144 | 262144 | 0 | global |
| 1 | 5 | GAIN_X | UQ16.16 | 0 | 262144 | 65536 | global |
| 1 | 6 | GAIN_Y | UQ16.16 | 0 | 262144 | 65536 | global |
| 1 | 7 | GAIN_Z | UQ16.16 | 0 | 262144 | 65536 | global |
| 1 | 8 | WS_X_MIN | S32 | -32768 | 32767 | -32768 | global |
| 1 | 9 | WS_X_MAX | S32 | -32768 | 32767 | 32767 | global |
| 1 | 10 | WS_Y_MIN | S32 | -32768 | 32767 | -32768 | global |
| 1 | 11 | WS_Y_MAX | S32 | -32768 | 32767 | 32767 | global |
| 1 | 12 | WS_Z_MIN | S32 | 0 | 65535 | 0 | global |
| 1 | 13 | WS_Z_MAX | S32 | 0 | 65535 | 65535 | global |
| 1 | 14 | EPOCH | U8 | 0 | 255 | 0 | global |
| 2 | 0 | LAMBDA_Q16 | UQ16.16 | 0 | 1048576 | 65536 | track |
| 2 | 1 | DENSITY_Q16 | UQ0.16 | 0 | 65535 | 32768 | track |
| 2 | 2 | MIN_LENGTH_TICKS | U8 | 1 | 128 | 4 | track |
| 2 | 3 | REST_POLICY | ENUM | 0 | 2 | 0 | track |
| 2 | 4 | FIXED_SCALE_MASK | U12 | 1 | 4095 | 4095 | track |
| 2 | 5 | BEND_CENTS | SQ8.8 | -307200 | 307200 | 0 | track |
| 2 | 6 | GATE_MODE | ENUM | 0 | 4 | 0 | track |
| 3 | 0 | ALPHA_Q16 | UQ0.16 | 0 | 65535 | 32768 | global |
| 3 | 1 | Z_ENGAGE | U16 | 0 | 65535 | 30000 | global |
| 3 | 2 | Z_RELEASE | U16 | 0 | 65535 | 36000 | global |
| 3 | 3 | MAX_STEP | U16 | 0 | 65535 | 4096 | global |
| 3 | 4 | SETTLE_FRAMES | U8 | 0 | 255 | 3 | global |

RULE `REST_POLICY`: 0 keep silence, 1 bridge short rests, 2 quantized rests. `GATE_MODE`: 0 Z, 1 touch, 2 bow, 3 either, 4 both. `FIXED_SCALE_MASK` uses bit 0 for pitch class C through bit 11 for B. CURSOR Z thresholds require `Z_ENGAGE < Z_RELEASE`. The existing UI must treat constants outside these indexed values as read-only until corresponding RTL consumers exist.
