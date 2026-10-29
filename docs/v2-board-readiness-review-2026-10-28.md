# V2 board-readiness review — 2026-10-28

This review uses the current checkout at `eb87408` on
`feat/loop-event-store`. It separates an early board smoke from the final V2
full-path acceptance gate.

## Current conclusion

The project now has a fresh current-source E2 board P&R/bitstream artifact, but
it is not yet ready for a final V2 board test because the 100 MHz timing gate
fails. The run is package-legal: CPU and SSPI are regular IO, `clk_50m` is at
E2/5, and PR2017/PR2028 are absent. The generated bitstream is retained as
timing-failure evidence only. The `.fs` under `impl/v2_audio_smoke_20261027/`
remains an early audio smoke artifact, and older `impl/v2_top/` outputs remain
historical.

## Gate classification

| Area | Current evidence | Readiness |
| --- | --- | --- |
| Contract, codec and parameter ranges | Python/SV contract and mutation checks; 32-slot, voice-steal, N-tone and wavetable field definitions | Scoped gate closed; downstream consumers still incomplete |
| Clock and sample cadence | 50 MHz → 100 MHz PLL, 48 kHz fractional scheduler, early I2S smoke P&R | Early hardware gate closed; final top I2S constraints remain open |
| Input/cursor/LIVE/Loop | Replay and standalone RTL gates; top smoke covers basic recorder/commit/play | Scoped evidence only; full-path timing and invalid/gap vectors remain open |
| Potts | Real recorder contour reaches the top simulation; measured `busy_cycles=1,868,573` | Simulation evidence only; final top uses `USE_POTTS=0` by default |
| Voice | 32×2 banked functional replay, release/revoice/vibrato and DPB model checks | Current-source 100 MHz P&R is open; old routed artifacts are historical |
| N-tone test mode | N=1/2/4/8/16/32 capture, radix-2 FFT sideband gate, standalone synthesis, A0 top smoke | Diagnostic path substantially closed; not a LIVE/LOOP substitute |
| Patch/wavetable/FX | Standalone patch, wavetable and reduced-FX gates | Final top has no patch/loader instances; FX remains `enable=0`, `level=0` |
| UART/telemetry | Byte parser, ACK/NACK, duplicate and snapshot standalone gates | Top telemetry `frame_ready` is tied low; no physical TX/CSR evidence |
| Final top P&R | Fresh E2 package-legal current-source run; 2.615 MHz actual Fmax, 3151 setup violations, 0 hold violations | Package gate closed; 100 MHz timing gate open |
| Board measurement | No final V2 programming, UART capture, I2S waveform or latency measurement | Not started |

## Remaining critical path

1. Close the top CSR/storage boundary. Add patch and wavetable shadow/active/
   CRC/version/APPLY/readback routing, with synchronous-read response handling.
   Keep UART command acceptance independent from a target module's busy state so
   an invalid or busy request returns an error instead of stalling `cmd_valid`.
2. Enable a nonzero reduced FX path from active configuration and align its
   valid/latency with I2S. Add the required band/octave selection behavior.
3. Add telemetry arbitration. ACK/NACK replies have priority, telemetry must
   consume the snapshot `ready` interface, and the actual UART TX must emit the
   22-byte telemetry frame at both 1 Mbaud and 115200 baud.
4. Make the final top timing path real: actual reader or equivalent valid input,
   LIVE/LOOP, non-empty recorder contour, `USE_POTTS=1`, 32×2 voice, nonzero FX,
   UART/telemetry and I2S all retained. Resolve the known front-end and voice
   timing violations, then rerun synthesis and P&R from the current commit.
5. Repair the banked voice state path that currently maps `age` and
   `steal_hold` to RAMREG and produces the 2.615 MHz result; preserve the
   functional replay while adding explicit latency/BRAM boundaries.
6. Recheck package constraints and I2S output timing against the actual top
   ports. A successful probe with stub inputs or swept modules cannot close this
   gate.
7. Only after the current-source P&R succeeds should the project generate the
   final `.fs`, hash it, program the board, and record board revision, UART
   frames, BCLK/LRCK/DIN captures, underrun status and trigger-to-waveform
   latency.

## Recommended execution workflow

Use one checkpoint per independently verified boundary:

1. Top CSR mux + patch/WT smoke.
2. Nonzero FX + I2S sample/latency smoke.
3. Telemetry TX arbitration + physical-baud simulation.
4. Full-path current-source synthesis/P&R and timing report.
5. Final bitstream hash and board smoke.
6. Board acceptance measurements and validation-report update.

At each boundary, record the exact commit, command, device, constraints,
resource/timing numbers and whether the result is a probe, stub, or real path.
Do not promote a standalone or stale artifact to final acceptance evidence.
