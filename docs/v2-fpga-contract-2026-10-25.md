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

## Control packet (11 bytes)

`A5 02 op address sequence data[31:24] data[23:16] data[15:8] data[7:0] crc[15:8] crc[7:0]`.
All multi-byte values are big endian. CRC is CRC-16/CCITT-FALSE (polynomial `0x1021`,
initial `0xFFFF`) over the first nine bytes. Addresses outside the ranges below are
rejected.

| Range | Region |
| --- | --- |
| `0x00–0x44` | legacy Loop |
| `0x48–0x5C` | patch/gesture |
| `0x60–0x7C` | wavetable/APPLY |
| `0x80–0x9C` | telemetry/diagnostics |
| `0xA0–0xAF` | test mode |

## Telemetry packet (22 bytes)

`5A 02 type sequence[15:8] sequence[7:0] x[15:8] x[7:0] y[15:8] y[7:0] z[15:8] z[7:0] note flags tick voice_bitmap[31:24] ... voice_bitmap[7:0] fifo_level fault_code crc[15:8] crc[7:0]`.
The body is 20 bytes; CRC-16/CCITT-FALSE covers the body. `x`, `y`, and `z` are
signed two's-complement 16-bit values. `voice_bitmap` is 32 bits; `fifo_level` and
`fault_code` are 8 bits.

## Implementation invariants

There is one V2 event layout, one control packet length, one telemetry packet length,
and one CSR address map. Any new RTL must import `v2_contract_pkg` and use these constants.
