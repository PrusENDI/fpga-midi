# V2 validation status

Updated: 2026-10-28. This is an in-progress evidence record, not a final acceptance report.
The binding requirements are the V2 implementation plan and V2 contract. Estimates,
independent software tests, standalone synthesis, routed timing and board measurements
are different kinds of evidence and must not be substituted for each other.

## Repository baseline and preserved files

- Started at `6bd5597` on `feat/loop-event-store`.
- V1 top, PC Capture & Loop, four-track Loop and four-voice synthesis remain baselines.
- Two pre-existing modified documents were excluded from all task commits:
  `docs/mgc3130-coordinate-calibration-spec.md` and
  `docs/mgc3130-z-coupling-clutch-rebase-realtime-design-2026-10-22.md`.
- The pre-existing untracked PDF is actually named `docs/技术文档.pdf`.
  The requested `docs/投稿的文档.pdf` was not present when its path was checked;
  no PDF was renamed, edited or deleted.

## Git checkpoint publication

Verified implementation checkpoints remain local on `feat/loop-event-store`.
The configured `origin` is a GitHub repository. An earlier push attempt was
rejected by the environment's automatic review as an external public write;
the local commits are preserved and no bypass was used. A later push requires
explicit authorization for that destination.

## Gate audit

Initial scoped reviews accepted code fixes without enforcing all plan evidence gates.
Those completion claims are superseded by this audit. Tasks 6–7 and 8–9 now have
scoped evidence; the final V2 top and board gates remain open.

| Task | Implementation / evidence | Gate status |
| --- | --- | --- |
| 1 contract | Corrections `097ff47`, `fe3ab72`, `4325d2f` add four indexed parameter families, concrete CSR/access/op/ACK/event definitions, signed two's-complement writes, Python/SV Q/scope/range metadata parity, and runnable SV width/layout assertions with mutation checks. | Contract/codec gate accepted by independent scoped review. Downstream RTL consumers and Task5 constant imports remain later gates. |
| 2 clock | Corrections `dfbf4ae`, `e18a68d` use GW5A `PLLA`: 50 MHz / 1 × 1 × 20 / 10 = 100 MHz. Manufacturer-model lock/reset/relock, injected unlock, two-edge reset release and 10 ns period tests pass. Scheduler counted 48,000 enables in 100,000,000 cycles with 2083/2084 intervals. Clock/scheduler/reset probe P&R: Fmax 194.654 MHz, setup/hold TNS 0, PLLA 1/6. | Clock/scheduler gate accepted after scoped independent review. I2S output constraints require the actual V2 transmitter/top ports at Task 12. This probe does not establish whole-design timing. |
| 3 input | Corrected latch → calibration → validity replay covers 976 frames, including signed17 X/Y, unsigned17 Z, gaps, saturation and invalid metadata; focused Python and ModelSim suites pass. | Accepted for its scoped gate; no whole-design timing claim. |
| 4 cursor | Integrated 976-row latch → calibration → validity → cursor replay, 12 Python tests, ModelSim pass, and standalone synthesis evidence. | Accepted for its scoped gate; no whole-design timing claim. |
| 5 rules | Separate LIVE/LOOP rule engines with backpressure, left-edge/rightward confirmation, reverse rejection and six-track recorder; Python and ModelSim suites pass. | Accepted for its scoped gate. |
| 6–7 loop/Potts | Six-track two-bank store/scheduler transaction replay passes; bounded Potts DP replay and backpressure pass. | Accepted for scoped gates; remaining coverage and device-level cycle timing are residuals. |
| 8 voices | Current 32-slot two-oscillator banked RTL includes deterministic voice-steal, bounded release, revoice and UQ8.8 vibrato. Python (8 tests), RTL gate, and 1,827-row/1,784-sample replay pass for portable and GW5A DPB models. | **Functional scoped gate accepted; current-source P&R remains open.** The post-fix Gowin CLI exits with code 1 before Tcl output, so the older 101.832 MHz routed artifact is historical and cannot close current-source timing. |
| 9 wavetable/FX | Explicit DPB-backed wavetable, patch and reduced FX path; ModelSim and Gowin resource/P&R probes. | **Accepted for scoped Task 9 storage/FX gate.** Final top timing and board evidence remain open. |
| 10 UART/telemetry | Byte-level control parser, CRC/version/op/access/data checks, duplicate replay, TX backpressure, double-buffer telemetry and CRC tests. | **Accepted for scoped Task 10 byte/snapshot gate.** Physical UART baud and CSR/top integration remain Task 11–12 evidence. |
| 11 PC UI/model | Contract-backed parameter model, fake transport, telemetry decoder, wavetable upload builder and hardware-free Tk shell. | **Accepted for offline/UI stop gate:** 174 Python tests pass; real serial remains excluded. |
| 12 | Independent V2 top and board validation. | In progress: RTL top simulation passes. A deterministic full-module timing probe retains input/calibration/validity, six-track recorder/store/scheduler, 32-voice DPB bank, FX and I2S with no synthesis sweep and closes 100 MHz; effective-reader/live timing and board capture remain open. |

## Toolchain

- Python: `C:\Users\fjcy\AppData\Local\Programs\Python\Python310\python.exe`.
- ModelSim: `C:\modeltech64_10.6d\win64` (`vlib`, `vlog`, `vsim`).
- Gowin: `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe`.
  It exists but is not on PATH. The earlier PATH-only check did not establish absence.
- Target: repository device declaration `GW5A-25A / GW5A-LV25MG121NES`.
- Generated simulation/synthesis/P&R outputs are under ignored `impl/` directories.
  Per-task reports retain commands; scripts must be retained for reproducibility.

## Cross-module discrepancies found before further implementation

1. The original V2 input extension cast unsigned sensor XYZ directly to signed16.
   Z=40000 then becomes negative, so the cursor's Z>36000 clutch release cannot fire.
   The corrected boundary must be recorded in the contract and covered by an actual
   latch → calibration → validity → cursor replay before the input gate passes.
2. Packed SV ranges with negative indices are legal; negative-index typedefs are not
   assertions. A runnable assertion test and a deliberately invalid mutation are needed.
3. An 11-byte control frame and address ranges alone do not freeze a usable register
   interface. Exact CSR addresses, access, fields, operations and response semantics are
   required before later modules can consume the contract.

## Task 10 UART/telemetry evidence (2026-10-26)

`rtl/v2_uart_link.sv` is the sole V2 byte-level protocol endpoint. It accepts the
11-byte control frame and exposes a ready/valid CSR command; replies are emitted as
the frozen 22-byte telemetry-shaped ACK/NACK frame. The parser is independent of
`sample_ce`. It caches all 22 reply bytes for exact duplicate replay, reports the
current reject reason instead of a stale registered error, and distinguishes
BAD_ADDRESS from BAD_DATA after CRC/version/op checks. PATCH shadow data remains
accepted at this boundary and is range-checked by the selected CSR bank.

`rtl/v2_telemetry_snapshot.sv` uses two banks. A capture is copied into the inactive
bank with CRC calculated over the 20-byte body before publication. TX backpressure
holds the selected byte; a capture coincident with the final byte handshake becomes
the next active frame without tearing. If both banks are occupied, the capture is
dropped and counted.

Reproducible command:

```powershell
.\scripts\test_v2_uart.ps1
```

The ModelSim run reports `tb_v2_uart_link PASS` and `tb_v2_telemetry PASS`. Coverage
includes valid PING/ACK, exact duplicate replay, sequence conflict, bad CRC,
bad-data mode write, TX backpressure, atomic field packing, CRC, full double-buffer
occupancy, dropped capture accounting, and simultaneous final-byte/capture handoff.
This is byte-level evidence only; physical 115200/1 Mbaud sampling, CSR-side
application, and top-level pin integration remain later gates.

## Task 11 PC model/UI evidence (2026-10-26)

`pc_receiver/fpga_v2_model.py` calls the single Python contract implementation for
CSR addresses, ranges, signed telemetry and CRC. `V2Parameters` is immutable at the
snapshot boundary; `apply_patch_delta()` returns a new clamped snapshot. The model
does not open a serial port. `FakeTransport` records outgoing frames and accepts
injected telemetry for replay tests.

`build_upload()` emits the complete 1024-sample shadow upload with 32 blocks, CRC,
version and APPLY trigger. `pc_receiver/fpga_v2_ui.py` is a small Tk shell with LIVE,
LOOP, STOP and BPM controls plus XY/Z-color, voice bitmap, FIFO and fault displays.
Transport threads post raw bytes into a queue; Tk alone decodes and updates widgets.
The UI never sends EventTable or PCM and keeps `synthwave_loop.py` as the offline
golden reference.

Validation command:

```powershell
python -m unittest discover -s tools -p 'test_*.py'
```

The run passes **171 tests**, including five Task 11 tests for clamping, signed
telemetry/CRC failure, complete upload bytes/CRC, fake transport replay and depth
color mapping. This closes the offline/UI gate only; physical serial and board
integration remain Task 12.
4. `V2_SIM` bypass has no frequency multiplication. Testbenches using it must drive a
   100 MHz simulated system clock. The hardware primitive path is tested separately
   with the actual 50 MHz board clock.

## Final claims intentionally pending

No final V2 top bitstream, board revision/capture, trigger-to-waveform latency, FX
level or whole-design timing has been accepted. Task 8 is accepted only for its
standalone voice-engine gate. No board was programmed during this work. The routed
voice probe cannot establish timing for calibration, cursor, FX or the final top.

## Task 12 timing-probe evidence (2026-10-26)

The current-source low-pin probe is `scripts/synth_v2_top_timing_timed20_20261026.tcl`
with top `sim/v2_top_timing_probe.sv`. It instantiates the independent V2 top with
`USE_GOWIN_RAM=1`, `USE_POTTS=0`, `PRESERVE_LOOP_PLANE=1`,
`PRESERVE_INPUT_PLANE=1` and `PRESERVE_INPUT_VALID=0`. The three preservation
parameters are timing-probe-only;
their defaults are zero in `rtl/mgc3130_v2_top.sv`. The probe uses a deterministic
transport/touch stimulus while marking XYZ invalid, so it exercises and retains the
input/calibration/validity and loop planes without claiming a live sensor waveform.

The authorized Gowin CLI run completed synthesis and P&R with no `NL0002 swept`
warnings. The netlist contains `v2_touch_info_decoder`, `mgc3130_input_latch`,
`v2_input_calibration`, `v2_position_validity`, `v2_loop_event_recorder`,
`v2_loop_event_store` and `v2_loop_scheduler`. The routed report is under
`impl/v2_top_timing_timed20_20261026/impl/pnr/` and records:

- 100.000 MHz generated PLL clock; actual Fmax **100.453 MHz**;
- setup violated endpoints **0**, hold violated endpoints **0**;
- setup/hold TNS **0.000 ns**;
- 5,890 logic (26%), 3,027 logic FF (13%), 17 DPB/BSRAM (31%), 18 DSP (65%),
  and 18 I/O ports (21%).
- Generated structural-probe bitstream SHA-256:
  `FEF5C1326F8831DFF4D64ED61BDE51F7D064A32209AF818279ADE19DB0BE346A`.

For comparison, enabling the real MGC reader with the same loop-preservation probe
produced 93.434 MHz and 48 setup violations, while a reader-stub probe with valid
synthetic XYZ produced 97.691 MHz and 24 violations. Those are diagnostic results,
not acceptance claims; they show that the remaining margin problem is in effective
reader/live/cursor activity and the current combinational note/velocity paths. The
100.453 MHz result is a complete retained-module structural timing gate, not a board
acceptance result. No final bitstream has been programmed, and no board I2S/UART or
trigger-to-waveform capture has been performed.


## Corrective replay evidence (2026-10-26)

- V2 raw boundary is now signed17 centered X/Y (`sensor_count - 32768`) and unsigned17 Z (`0..65535`), with default Z workspace `0..65535`. Synthetic vectors cover sensor 0, 32767, 32768, 65535 and Z 40000/65535; source provenance is recorded in `tools/testdata/v2_input/README.txt`.
- Latch timestamps are free-running and latched only on `report_valid`; frame transport strobe includes invalid/error reports. Epoch zero is the unqualified/default frame epoch and nonzero APPLY epochs are checked by calibration/validity. Explicit `v2_touch_info_decoder` decodes low-five electrode bits; zero, tap-only, absent and error fields do not assert touch or presence.
- `tools/generate_v2_input_replay.py` replays `tools/capture_fast_01.csv` (hex XYZ) and appends eight synthetic boundary/quality rows to `tools/testdata/v2_input/replay_fast_01.vec` (976 frames). `sim/tb_v2_input_replay.sv` compares every frame's sequence, timestamp, XYZ when valid, valid/lost/degraded, gap count, reason and note permission. ModelSim result: `tb_v2_input_replay PASS frames=976`.
- Touch decoder result: `tb_v2_touch_info_decoder PASS`. Focused Python suite: 8 passed. V1 latch plus decoder compilation: 0 errors.
- Standalone Gowin arithmetic synthesis command retained in `scripts/synth_v2_input_arithmetic.tcl`, invoked with absolute `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe`; log/report retained under `impl/v2_input_arithmetic_synth/`. Synthesis completed and reported 0 LUT/ALU after optimization because the probe instance was swept; warnings EX2420/EX3101 identify inferred combinational latches in the current arithmetic coding and NL0002 records the sweep. No utilization or timing claim is made from this swept probe.

Open evidence: a cursor-integrated replay remains downstream Task 4 evidence; the preserved arithmetic synthesis resource count is now available below.

## Corrective replay closure for Task 3 (2026-10-26)

- The real latch → calibration → validity path now carries explicit saturation and replay sequence metadata. Sensor endpoints are treated as coordinates; saturation is asserted only by the explicit V2 input. Sequence discontinuities are rejected by calibration as GAP and remain modulo-safe across `0xffff -> 0`.
- The replay compares all 976 rows, including invalid, saturated, explicit-gap, sequence-gap, wrap, and boundary rows. It checks aligned sequence/timestamp, signed17 X/Y and unsigned17 Z conversion, zeroed invalid outputs, quality flags, gap count, reason, note permission, and idle-cycle no-leakage. ModelSim result: `tb_v2_input_replay PASS frames=976`.
- Focused Python result remains `8 passed`; `tb_v2_touch_info_decoder PASS`; a temporary compatibility copy of the existing V1 reader touch harness with all V2 ports explicitly declared reports `tb_reader_touch PASS`. Legacy V1 source files and user-dirty documents remain untouched. The original wildcard harness is a pre-existing harness limitation because it does not declare the V2 ports.

Task 3's RTL/reference replay and arithmetic synthesis evidence are closed for this corrective round. Cursor-integrated replay remains downstream Task 4 evidence.

## Replay oracle tightening (2026-10-26)

The replay test now uses an independent free-counter model for timestamp expectations; no capture timestamp is injected into the latch. It asserts latch/calibration timestamp alignment, every raw and quality field, reason equality across calibration and validity, and validity equality across both bundles. It also includes a reproducible adjacent A/B report pair with no idle edge between reports: `tb_v2_input_replay PASS frames=976 adjacent=A/B`.

## Synthesis-only preservation fix (2026-10-26)

The arithmetic probe now exposes registered calibration/validity outputs and an observable checksum, with `keep_hierarchy` on both datapath instances. Absolute Gowin synthesis completed successfully. The report/log at `impl/v2_input_arithmetic_synth/impl/gwsynthesis/` show 72 LUT, 124 FF, 0 latch, 0 ALU, and 0 BSRAM. No DSP is inferred because the Q16.16 arithmetic maps to fabric logic. NL0002 is gone; EX2420/EX3101 remain at the calibration `always_comb` sign-extension temporary (line 140). This is synthesis-only evidence with no P&R or timing claim.

## Task 4 corrective gate closure (2026-10-26)

The file-driven cursor replay is now an end-to-end latch → calibration → validity → cursor test. `sim/tb_v2_cursor_replay.sv` compares all 976 rows, including real `capture_fast_01.csv` data and eight synthetic boundary/quality rows, for cursor coordinates, pitch, velocity, depth, state, point/stable validity, rebase pulse, sequence, independently modeled free-counter timestamp, and audio snapshots. The source capture timestamp in the cursor vector is metadata only and is never injected as the RTL latch timestamp. Result: `tb_v2_cursor_replay PASS rows=976`.

The replay includes adjacent registered stages, idle cycles, simultaneous sample capture, startup median sizes, filtered-Z motion alpha, negative fixed-point paths, u16 saturation, high-Z release/rebase/settle, pure-Z motion, invalid/gap/saturation/degraded recovery, and explicit initial left-edge arm semantics. Python result: 12 tests passed; existing cursor smoke: `tb_v2_cursor_filter PASS`.

Task 4 standalone synthesis is reproducible with `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe scripts/synth_v2_cursor_filter.tcl`. Its report at `impl/v2_cursor_synth/impl/gwsynthesis/v2_cursor_syn.rpt.html` records 10,613 LUT + 692 ALU, 947 FF, 14 DSP, 0 latch, and 0 BSRAM. Only unused calibration reason bits are warned. This is synthesis-only evidence; no P&R/Fmax claim is made.

The validity alignment was then tightened: the cursor now consumes the registered `v2_position_validity` outputs for the same calibrated frame through an explicit delayed strobe and metadata bundle. Strict replay still reports `tb_v2_cursor_replay PASS rows=976`, and the Python suite remains 12 passed. This closes the prior cursor validity bypass concern without changing the expected vector semantics.

The replay also latches `left_edge` at the report boundary and carries it through the same staged transport. A centered-coordinate explicit-arm vector passes with `ENGAGED` and no `REBASED` pulse, so initial arm evidence does not depend on mapped-X edge detection. The adjacent A/B transport check remains enabled.

Task 6's earlier 16-slot statement is superseded by the 2026-10-27 32-slot
gate below. The historical replay remains retained as an earlier RTL-only
record; current capacity and P&R evidence is recorded in the Task 6 section.
Task 7 Potts commit evidence: the standalone fixed-point commit FSM and Python
reference cover a 128-tick contour, A-minor pentatonic candidates, minimum
segment length, rest masking, bounded event RAM, backtrace-valid completion,
and held output backpressure. The measurement script reports the observed RTL
cycle count; the 41 us design figure remains an estimate until a device-level
timing run. The top now captures NOTE_ON pitch values indexed by recorded tick
from the recorder holding register into `potts_contour[0:127]`, so the COMMIT
input is no longer structurally tied to an all-zero contour. `USE_POTTS` remains
disabled in the default top regression, and no real-contour top P&R or boundary
timeout measurement has been claimed.

The follow-up top regression `scripts/test_v2_top_potts.ps1` now measures
`busy_cycles=1,868,573` for the current eight-event real-recorder contour,
with `backtrace_valid=1`, `overflow=0`, and one emitted event. While the DP is
busy it accepts a read-only UART status frame and the independent `sample_index`
continues to advance. The DPB-backed store remains boundary-gated, so the test
forces a loop boundary only after Potts completion before checking publication.

Both V2 store implementations now implement a contract-aligned boundary timeout:
the default is 3,400,000,000 100 MHz cycles (34 seconds), timeout clears only
the shadow metadata, retains the active bank, leaves `commit_ack` low, and
latches `commit_timeout`/`commit_wait_cycles`; ABORT clears the pending request
and diagnostics. `scripts/test_v2_loop_store_timeout.ps1` passes with an
eight-cycle override, and `scripts/test_v2_top_commit_timeout.ps1` passes with
a 300,000-cycle override while the top sample scheduler remains live. This is
RTL/simulation evidence; routed 100 MHz Potts timing and board measurements are
still open.

## Task 8 voice-engine evidence (2026-10-26)

- `python -m unittest tools.test_v2_voice_vectors -v`: 6 tests passed. Vectors
  cover 1, 8 and 32 allocations, 33rd overflow without changing existing slots,
  release/all-notes-off, revoice phase preservation, bounded detune targets,
  attack/decay/sustain, two-oscillator saturation and round-robin scan order.
- Fresh ModelSim compile has zero errors and zero warnings. `tb_v2_voice_engine`
  reports `PASS voices=32 scan_cycles=32 release_samples=16`.
- The routed Gowin probe uses GW5A-25A and an explicit 10 ns `clk_sys_100m`
  constraint. The latest report records 8,982 LUT + 687 ALU, 6,855 logic FF
  plus 18 I/O FF, 0 BSRAM and 0 DSP. P&R completes and generates a probe
  bitstream, but timing reports actual Fmax 58.253 MHz versus the 100 MHz
  constraint, setup TNS -34642.668 ns over 9,715 endpoints, and hold TNS 0.
- This is a real timing failure, not an estimate. The Task 8 Stop gate remains
  closed and Task 9 is intentionally not started. The probe is evidence for the
  engine's current critical path only; it is not the final V2 top or an I2S or
  board result.

## Task 8 recompose/root-cause audit (2026-10-26)

- Python and ModelSim were rerun after the recompose attempt: 6 Python tests
  passed; `tb_v2_voice_engine PASS voices=32 scan_cycles=32 release_samples=16`,
  with zero compile warnings and zero simulation errors.
- The License Manager GUI reports `Server is OK`, server
  `106.55.34.119:10559`, and expiry `2027-10-19`. A normal Codex-sandbox
  process cannot open the license-server socket, so `gw_sh.exe` exits before
  Tcl with code 1 and no stdout/stderr. This is an execution-environment
  network restriction, not evidence that the license is invalid.
- Running the same signed `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe`
  through an external-network-enabled CLI process enters Tcl, completes
  synthesis and P&R, and emits `V2_VOICE_SYNTH_PASS` and
  `V2_VOICE_PNR_PASS`. The reproducible wrapper is
  `scripts/run_gowin_cli.ps1`; it sets the Gowin installation and license
  environment without modifying the installed `gwlicense.ini`.
- Fresh CLI evidence is under `impl/v2_voice_synth_cli_20261026/`. The new
  routed report records Fmax 58.253 MHz, setup TNS -34642.668 ns over 9715
  endpoints, hold TNS 0, and the same worst data delay of 17.134 ns. The new
  probe bitstream is `impl/v2_voice_synth_cli_20261026/impl/pnr/v2_voice.fs`
  with SHA-256
  `7AE9CACD8016E1E42D34DC4EC38807B48A0DEB25804DA095C11851293D8FDAD7`.
- The wrapper probe entered the Gowin Tcl console and returned
  `GW_WRAPPER_TCL_OK` with exit code 0; the fresh ModelSim voice regression
  also passed with zero compile warnings and zero simulation errors.
- The valid routed timing paths identify the implementation root cause. The
  worst path launches from `engine/scan_slot_*` and terminates in
  `mixed_sample` or the variable-indexed `phase/step/target` RAM writeback,
  with roughly 17 ns data delay under a 10 ns constraint. Synthesis extracts
  the unpacked per-voice arrays into many RAM/REG banks, while the report uses
  0 BSRAM; the variable scan address fans into RAM CE/D selection and the same
  cycle also performs two oscillator contributions, accumulation and output
  saturation. This is an architectural single-cycle read/compute/writeback
  path, not a missing-clock or bad-SDC issue.
- The previous two optimizations (registered `scan_slot`, synchronous local
  reset and bounded 512-step glide) reduced the critical path from the first
  38.678 MHz result to 58.253 MHz, but did not close 100 MHz. The next valid
  repair must pipeline the state-bank read/compute/writeback or explicitly
  map a supported RAM mode; changing only constraints would conceal the real
  failure.

## Task 8 timing closure attempt — 2026-10-26 (superseded)

An earlier cleanpipe artifact was reported after the three-stage scan pipeline
was added. That artifact must not be used as closure evidence for the current
working RTL: subsequent command-boundary edits changed the inferred storage
structure, and a fresh rebuild of the current source does not reproduce its
resource or timing result.

`tb_v2_voice_engine PASS voices=32 scan_cycles=32 release_samples=16`

The reproducible current-source run is retained under
`impl/v2_voice_synth_task8_alias_probe_20261026/`. ModelSim and the
Python voice vectors pass, but the routed report records:

- Fmax: **76.756 MHz** at a 100.000 MHz constraint.
- Setup violating endpoints: **6,108**; setup TNS: **-7,717.888 ns**.
- Hold violating endpoints: **0**; hold TNS: **0.000 ns**.
- Resources: 8,820 LUT, 607 ALU, 7,241 logic FF, **0 BSRAM**.
- Worst setup path: `active` to variable-indexed state-bank write logic,
  approximately 16.7 ns data delay.

The new root cause is storage inference, not the oscillator arithmetic alone.
The older 100.021 MHz artifact used 8 SDPB blocks for the state arrays. The
current source is functionally equivalent at the interface but Gowin expands
the arrays into logic registers; the resulting high-fanout state write-enable
network fails timing. Removing event aliases does not change this result. The
next repair must make the state-bank RAM template deterministic, preserve the
registered scan stages, and then repeat the full 100 MHz P&R gate. Task 8
therefore remains **blocked** until a fresh run has zero setup and hold
violations.

## Task 8 BSRAM architecture experiment — 2026-10-26

The local Gowin installation was used through `scripts/run_gowin_cli.ps1` with the configured license server. The installed references are `UG285-1.4E_Gowin BSRAM & SSRAM User Guide.pdf`, `SUG550-2.4E_GowinSynthesis User Guide.pdf`, `prim_syn.v`, and the `RAM_SDPB` HTML guide under `C:\Gowin\Gowin_V1.9.12.04_x64\IDE`.

The minimal explicit `DPB` bank in `rtl/v2_voice_state_bank.sv` is 32 words deep and uses 16-bit lanes. Its routed probe under `impl/v2_voice_state_bank_probe_20261026c/` preserves 13 `DPB` lanes and has 0 setup and 0 hold violations at 100 MHz. This isolates the previous failure to inferred storage and shows that the device can meet the clock with an explicit state bank.

The exploratory banked voice engine in `rtl/v2_voice_engine_banked.sv` has a focused ModelSim test and a routed result under `impl/v2_voice_synth_banked_20261026/`: 11 BSRAM, actual Fmax 100.002 MHz, setup TNS 0, hold TNS 0. It is not yet Task 8 closure because target-frequency metadata is still inferred as RAMREG and the critical setup slack is 0.000 ns. The next implementation step is to pack target state into the deterministic bank and rerun the full voice regression and P&R gate.

Running the current unbanked source at a 20 ns constraint is a useful diagnostic fallback because its measured Fmax is above 50 MHz, but it does not satisfy the V2 contract. The V2 clock architecture remains a 50 MHz board input through the GW5A PLL to a 100 MHz system clock, with 48 kHz generated by sample enable; no second free-running audio clock is introduced.

### Banked voice replay and latest timing evidence

The banked experiment now has an independent file-driven replay generated by `tools/generate_v2_voice_replay.py`. `scripts/test_v2_voice_banked.ps1` runs 1,827 rows / 1,784 audio samples against both the RTL memory fallback and the installed GW5A `prim_sim.v` model; both runs report `tb_v2_voice_replay PASS` with a one-LSB sample tolerance and no simulator errors. The replay covers non-multiple-of-512 glide targets, ADSR attack saturation, full 32-slot allocation and overflow, scan-boundary event holding, release, all-notes-off, and slot reuse.

After correcting fixed-width attack saturation and bounded glide, the reproducible banked P&R run is `impl/v2_voice_synth_banked_20261026c/`. It reports actual Fmax 100.004 MHz, setup TNS 0, hold TNS 0, 11 DPB/BSRAM, 2,568 FF, 2,009 LUT and 819 ALU. The netlist retains eleven explicit DPB lanes. The reported worst setup slack is 0.000 ns on the remaining metadata target array write-enable path, so this is functional/timing evidence for the banked architecture but still requires margin improvement before it is accepted as the final Task 8 implementation.

The diagnostic unbanked 20 ns run is retained under `impl/v2_voice_synth_50m_diag_20261026/`: actual Fmax 53.660 MHz with setup/hold TNS 0. It demonstrates that 50 MHz is a temporary fallback, not a solution to the V2 requirement, because it leaves the state arrays in logic and retains the large resource footprint.

The device-specific official reference is the installed Arora V guide
`C:\Gowin\Gowin_V1.9.12.04_x64\IDE\doc\EN\UG300-1.3.6E_Arora V BSRAM & SSRAM User Guide.pdf`.
UG300 Section 3.1 defines DPB's 16-bit port and address/write-enable behavior;
Section 3.3 documents SDPB widths and address mapping. SUG550 Section 4.2 and
Section 5.16 cover one-read/one-write RAM inference and `syn_ramstyle`. The
repository's `rtl/loop_event_ram.sv` is an additional project-local DPB lane
example. Applying `syn_ramstyle="block_ram"` to the current target arrays
produces Gowin IF0007 (attribute not applicable), so the final fix must keep
single-write arbitration and explicit DPB mapping rather than rely on an
attribute over a multi-write array.

## Task 8 closure — explicit target bank and 100 MHz margin (2026-10-26)

The final repair packs both glide targets into the same 240-bit state word as
phase, increment, envelope and mix metadata. `rtl/v2_voice_state_bank.sv`
maps that word to fifteen explicit 16-bit GW5A DPB lanes. The former
variable-indexed `target_a/target_b` arrays are gone from the hot state path;
the synthesis log only reports the small note metadata array and reports no
`IF0007` RAM-style warning for the state bank.

REVOICE is now a one-entry pending command. Its note and two target values are
accepted only when the scan is idle, captured into the registered read stage,
and written back through the same serialized DPB port as the normal scan. A
second REVOICE is back-pressured while the mailbox is occupied. This removes
the event-side multi-write hazard while preserving phase and the reference
model's bounded glide behavior.

The fresh source-matched run is `impl/v2_voice_synth_task8_targetbank_100m_20261026/`,
reproduced by `scripts/synth_v2_voice_engine_task8_targetbank_100m_20261026.tcl`
through the licensed Gowin CLI wrapper. The routed report records:

- constraint: `clk_sys_100m`, 10.000 ns;
- actual Fmax: **101.832 MHz**;
- setup violated endpoints: **0**, setup TNS **0.000 ns**;
- hold violated endpoints: **0**, hold TNS **0.000 ns**;
- worst setup slack: **+0.180 ns**;
- resources: **15 DPB/BSRAM**, 3,060 logic, 977 FF, 0 SSRAM/RAM16.

The complete replay remains green after the target-bank change: 1,827 vector
rows and 1,784 samples pass against both the RTL memory fallback and the GW5A
`prim_sim.v` model, including REVOICE, 32-slot allocation, 33rd overflow,
release, ALL_NOTES_OFF, scan-boundary backpressure and slot reuse. This closes
the Task 8 standalone stop gate. It does not close the final V2 top or board
gate.

### Task 9 resource gate — explicit DPB-backed wavetable, patch and FX (2026-10-26)

The first Task 9 probe is retained at `impl/v2_task9_wavetable_fx_20261026/`.
Its variable-indexed delay/comb arrays synthesized as **16,443 FF, 9,701 LUT,
0 BSRAM**, and placement stopped with `PR0003` and 1,822 unplaced registers.
The same report showed `v2_patch_bank` swept because the probe had no
observable patch controls. This is a storage-inference failure, not a GW5A
capacity result.

The repair uses explicit GW5A `DPB` lanes with synchronous one-cycle reads:
two FX stores (1024x16 delay and 256x16 comb), six A/B/C wavetable banks
(active/shadow), and two 1024x32 patch banks split into 16-bit lanes. Upload
and APPLY keep the shadow CRC/version checks and swap only at idle or a Loop
boundary. FX remains gain -> one-pole LP -> delay -> one-comb reverb, with
bounded Q1.15 feedback and saturation; the memory read latency is internal to
the effect block and does not delay event, Loop, voice or I2S control paths.

Focused evidence:

- `impl/modelsim_v2_task9_wt_fx_final/` reports `tb_v2_wavetable_fx PASS`.
- `impl/modelsim_v2_task9_patch_20261026i/` reports
  `tb_v2_patch_bank PASS version=1`, including incomplete-bank rejection,
  CRC validation and active readback.
- `impl/v2_task9_dpb_full_20261026/impl/gwsynthesis/` synthesizes the dynamic
  full probe with **12 DPB**, **6,625 FF**, and **19,751 logic**. Its P&R is
  not used because exposing every upload control as top-level ports creates
  361 package pins.
- The valid small-pin P&R probe is `impl/v2_task9_pnr_20261026/`, reproduced
  by `scripts/synth_v2_task9_pnr_20261026.tcl` through
  `scripts/run_gowin_cli.ps1`. It completes placement, routing, timing
  analysis, bitstream and power generation with **5,886 logic**, **2,195 FF**,
  **10 DPB**, **4 DSP**, and 46/86 I/O. The synthesis timing report for the
  100 MHz constraint records **82.970 MHz** Fmax and -2.052 ns slack for this
  deliberately dynamic diagnostic probe; this is a resource/P&R probe, not a
  final V2 top timing claim. The final rerun reports **5,902 logic**, **2,195
  FF**, **10 DPB**, and **5 DSP**. The bitstream SHA-256 is
  `36568306ED6E860D8CAFF8FD70348924E6AF450F6E39D3F3451341808184BD33`.

Task 9's standalone storage/FX stop gate is satisfied at reduced FX level
(chorus absent, one comb retained). The final V2 top still needs its own I/O,
timing and board evidence in Task 12.

### Task 9 reproducible simulation scripts — 2026-10-28

The previously retained Task 9 ModelSim logs are now reproducible from the
current checkout with two focused scripts:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_wavetable_fx.ps1
V2 wavetable/FX simulation PASS

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_patch_bank.ps1
V2 patch bank simulation PASS
```

The wavetable/FX replay checks incomplete-table rejection, CRC16/CCITT-FALSE,
boundary/idle APPLY, active sample readback, and nonzero reduced FX status. The
patch replay checks range rejection, incomplete APPLY rejection, full shadow
upload, CRC validation, atomic idle APPLY, active-version increment, and active
readback. Both current-source logs report zero simulator errors; the only
warning is ModelSim's expected `-novopt` visibility warning. These remain
standalone gates: the top-level path still has FX disabled and does not yet
connect wavetable/patch shadow/active control to the final UART/CSR path.

## Task 8.5 independent N-tone test mode — 2026-10-28

The current source adds `rtl/v2_test_mode.sv` as an isolated observability
module. Selector 1 accepts a tone count from 1 through 32 and generates fixed
DDS tones at 220 Hz × k. A zero count stops the mode and clears phase; an
out-of-range count latches a fault. The module exposes the active bitmap,
sample counter and fault state and does not consume EventTable data or modify
LIVE/LOOP state.

The reproducible gate is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_test_mode.ps1
```

It compiles and runs `sim/tb_v2_test_mode.sv`, producing 48 kHz fixed-window
captures for N=1, 2, 4, 8, 16 and 32. `tools/test_v2_spectrum.py` checks the
expected 220 Hz × k fundamentals over a ±10 Hz search window, requires each
peak magnitude to exceed 1.0. It then applies a 4096-sample Hann window and a
pure-Python radix-2 FFT, retaining the three-bin main-lobe neighborhood around
each expected fundamental. The gate rejects any capture with power-based
`sideband_ratio > 0.02`. The current run reports 0–1 Hz peak error and
sideband ratios **0.0026–0.0090** across `files=6`. This closes the independent
RTL/fundamental/sideband portion of Task 8.5. Standalone synthesis/resource
evidence and final top CSR/I2S/board integration remain separate gates; the
mode cannot substitute for LIVE/LOOP audio validation.

The current top now routes `TEST_SELECT_0` writes and delayed readback through
the V2 UART command boundary. While `test_active` is asserted, the test sample
and valid pulse bypass the disabled FX instance and feed the existing I2S
transmitter; the normal voice sample path is selected otherwise. The fresh
`scripts/test_v2_top.ps1` regression writes N=1, reads back the packed active
count, observes an I2S sample-valid pulse, and confirms that the voice bitmap
stays zero. This is a top-level simulation smoke check, not board or timing
evidence.

### Task 8.5 standalone synthesis/resource probe — 2026-10-28

The independent synthesis command is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_test_mode.tcl).Path
```

It completes with `V2_TEST_MODE_SYNTH_PASS` and writes
`impl/v2_test_mode_synth_20261028/impl/gwsynthesis/v2_test_mode_syn.rpt.html`.
The probe keeps every status/sample output observable and is deliberately
synthesis-only because its 158 I/O ports exceed the GW5A package. Current
resource usage is **9,252 LUT**, **782 ALU**, **1,060 registers**, **0 latch**,
and **0 BSRAM** (the phase array is extracted during synthesis but maps to
logic in the final report). The report's aggregate logic figure is **10,036**;
the LUT resource summary is used for the LUT count. The synthesis estimate is
**12.337 MHz** with 114 logic levels; this is a standalone unpipelined probe
estimate, not a routed 100 MHz claim. A first P&R attempt is retained as
diagnostic only and stops at Gowin PA2112/PA2024 for the over-sized probe
interface, so this does not close final-top P&R timing.

## Task 1 contract increment — 2026-10-27

The remaining Task 1 interface deltas are now frozen in
`docs/v2-fpga-contract-2026-10-25.md`, `tools/v2_contract.py`, and
`rtl/v2_contract_pkg.sv`. The increment covers two banks × six tracks × 32
96-bit slots, five-bit slot addresses, six-bit per-track counts, a 16-bit voice
steal counter with the released/oldest/velocity/voice-ID priority order, the
N-tone selector and 1–32 count range, the `WT_SELECT` band[11:9]/octave[15:12]
packing, and the phase/delta-cents vibrato readback masks.

Reproducible checks from the current source:

```text
python -m unittest tools.test_v2_contract -v
Ran 12 tests ... OK
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_contract.ps1
V2 contract PASS; layout and width mutations rejected
```

This closes the Task 1 contract-increment stop gate. It does not claim that
the downstream loop store, voice engine, test mode, wavetable loader, or top
level CSR consumers already implement these newly frozen fields.

## Task 6 32-slot Loop storage and boundary gate — 2026-10-27

The V2 loop interfaces are now width-consistent: two banks × six tracks × 32
96-bit slots, 5-bit slot/read indices, six-bit per-track counts, a 36-bit
packed `record_count`, and a 192-slot copy boundary. The portable
`rtl/v2_loop_event_store.sv`, `rtl/v2_loop_event_recorder.sv`, and
`rtl/v2_loop_scheduler.sv` no longer use the old 16-slot/4-bit/5-bit boundary.
The V1 `loop_event_store.sv` path was not changed.

The fresh command
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_loop_transactions.ps1`
reports PASS for the portable recorder test, the recorder→store→scheduler
transaction test, and the official GW5A `prim_sim.v` test of
`rtl/v2_loop_event_store_dpb.sv`. The vectors fill all 32 slots, reject and
latch the 33rd append as overflow, read and schedule slot 31, hold scheduler
output under backpressure, publish a COMMIT only at the boundary, and preserve
the active bank across PREPARE_RECORD/ABORT. The recorder test also reads back
its local slot 31 and checks its six-bit count.

The independent physical probe is
`impl/v2_loop_transactions_probe_20261027/`, reproduced by
`scripts/synth_v2_loop_transactions_probe.tcl` through the licensed Gowin
wrapper. It uses six explicit 16-bit DPB lanes in
`rtl/v2_loop_event_store_dpb.sv` and a 100 MHz `clk_sys_100m` constraint on
`GW5A-LV25MG121NES`. The routed report records actual Fmax **109.898 MHz**,
setup and hold violated endpoints **0/0**, setup and hold TNS **0.000/0.000 ns**,
worst setup slack **+0.901 ns**, **889 logic**, **317 logic FF**, **6 DPB**, and
**15 constrained I/O**. The probe bitstream
`impl/v2_loop_transactions_probe_20261027/impl/pnr/v2_loop_transactions_probe.fs`
has SHA-256
`776BF548924AA33B8B80B4CFE79C45DD559B197AB57FF6F21BA258E8DDC05C2F`.

This is scoped storage/scheduler evidence. The physical probe has compact
diagnostic ports and does not include the final MGC3130 reader, voice engine,
Potts, I2S, UART/telemetry, or board wiring. The production `mgc3130_v2_top`
now selects the DPB wrapper; its top-level ModelSim regression is recorded
below. A final top P&R is still required before Task 12 can close.

The timeout-counter RTL added after that probe was not assigned a new physical
artifact: rerunning
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 -TclScript scripts/synth_v2_loop_transactions_probe.tcl`
on the current source exited with code 1 before `gw_sh.exe` emitted Tcl output.
The hash and timing numbers above therefore remain historical pre-timeout probe
evidence and are not reused as a current-source timing claim.

## DPB-backed V2 top integration — 2026-10-27

`rtl/mgc3130_v2_top.sv` now instantiates `v2_loop_event_store_dpb.sv`, and
`scripts/test_v2_top.ps1` compiles that source instead of the portable store.
The regression still exercises UART mode/track/record/commit controls, a real
recorder write, boundary-gated bank publication, PLAY scheduling and voice
allocation. The original fixed 1,000-cycle PLAY window was too short for the
DPB synchronous read latency; the test now holds `sample_index=0` until
`voice_bitmap` becomes nonzero, with a 4,000-cycle timeout. The fresh run
reports `tb_mgc3130_v2_top PASS samples=55`.

The failure investigation also checked the DPB lane data at track 2/slot 0:
the recorded word `0a00013c6400000000000000` was returned with
`read_slot_valid=1`, so the corrected test is a latency-alignment fix rather
than a storage-data workaround. This is top-level simulation evidence only;
the current Gowin scripts still use diagnostic probe tops and do not close
full-path timing or board validation.

## Task 12 top CSR status increment — 2026-10-28

The top smoke now reads `V2_CSR_STATUS` after boundary publication and checks
that bit 8 (`active_valid`) is set while the committed Loop bank is active.
The top response mux preserves `mode[2:0]`, reports `loop_active_valid`, and
sets the contract fault bit when protocol, recorder, commit-timeout or test
mode faults are present. This closes only the status readback slice; the
remaining POSITION/DIAG/PATCH/WT/TLM registers, PLAY/RESET/STOP semantics,
telemetry TX arbitration, BPM timing and final top P&R/board gates remain
open.

The same top smoke now forces the validity outputs and asserts that
`frame_degraded` and `frame_gap` arrive at the LIVE rule engine ports. The
previous constant-zero connections were removed. This is a wiring invariant;
full invalid/gap event vectors and end-to-end qualification remain part of the
open Task 12 top test.

## Task 7 top-level Potts contour measurement — 2026-10-27

`scripts/test_v2_top_potts.ps1` runs `mgc3130_v2_top` with `USE_POTTS=1` and
the DPB-backed loop store. It injects eight NOTE_ON events with increasing
ticks through the recorder, verifies that the recorder writes those values
into the top-level contour holding bank, then triggers COMMIT. The run reports
`tb_mgc3130_v2_top_potts PASS busy_cycles=1868573 events=1`, with
`backtrace_valid=1` and `overflow=0`. The store's `commit_pending` remains set
until the test supplies a loop boundary, after which `loop_active_valid` is
published.

The measured cycle count is a simulation-domain budget for the current FSM;
it is not a 100 MHz routed result. The rest mask remains empty and the top
still defaults `USE_POTTS=0`; routed 100 MHz timing, non-empty rest-mask policy,
and board evidence remain open. Boundary timeout/pending behavior is now
explicit and covered by the dedicated short-cycle regressions above.

## Task 2.5 audio smoke gate — 2026-10-27

The independent early audio slice is now implemented in
`rtl/v2_audio_smoke_top.sv`, with the replay in `sim/tb_v2_audio_smoke.sv` and
the reproducible command `scripts/test_v2_audio_smoke.ps1`. A fresh run reports
`tb_v2_audio_smoke PASS`; the checks cover PLL lock/reset, fractional 48 kHz
sample cadence, 30,720 BCLK edges, 480 LRCK rising edges, and the fixed DDS
sample sequence (`samples=479`, `i2083=319`, `i2084=159`). This slice uses one
100 MHz PLL clock and a `sample_ce`; it does not create a second free-running
audio clock and is not the final V2 top.

The source-matched Gowin run is `impl/v2_audio_smoke_20261027/`, reproduced with
the licensed CLI wrapper and the current `mgc3130_v2_audio_smoke.cst/.sdc`.
The P&R report identifies device `GW5A-LV25MG121NES`, 50 MHz `clk_50m` into
one PLLA, generated 100 MHz clock, and constrained ports E1/L2/G1/L3/C2. The
timing report records actual Fmax **137.296 MHz** for the 100 MHz generated
clock, setup and hold violated endpoints **0/0**, setup and hold TNS
**0.000/0.000 ns**, and worst setup slack **+2.716 ns**. Resource usage is
**187 logic** (156 LUT + 31 ALU), **126 FF**, **5 I/O**, and **1 PLLA**.
The generated bitstream is
`impl/v2_audio_smoke_20261027/impl/pnr/v2_audio_smoke.fs` with SHA-256
`4641A8C3C1CF28AD62B1C95C59753D3BD56B2BA7F862563A0F5CF9F5D8936A24`.

An earlier attempt using the board-labelled E2 input did not produce a legal
PLLA path: Gowin reported `PR2028 constrained location is useless` and
`PR2017 clk_50m cannot be placed ... dedicated pin (CPU/SSPI)`. E1 is therefore
the reproducible package-legal input for this smoke top. The board-level E2
oscillator allocation remains unresolved, and no DAC-side capture has been
performed. This closes the smoke simulation, I/O-constraint, and independent
P&R gate only; it is not board-level audio evidence and does not close Task 12.

## Task 8 voice-steal/vibrato continuation — 2026-10-28

The previous banked replay failure was root-caused before changing the oracle.
The steal hold counter was decremented with the unsynchronised `rd_releasing`
flag rather than the release flag belonging to `calc_slot`, so it advanced only
when two pipeline addresses happened to coincide. While the hold remained set,
the release envelope could also subtract below zero and wrap to `16'hFFFF`.
`rtl/v2_voice_engine_banked.sv` now carries `calc_releasing` through the compute
pipeline, uses a 16-bit hold for eight complete 32-slot passes, clamps the quiet
release tail at zero, and writes the pending note on the same edge that retires
the victim. This keeps the final victim sample intact and publishes the reused
slot at the expected sample boundary.

The current source passes the following checks:

```text
python -m unittest tools.test_v2_voice_vectors -v
Ran 8 tests ... OK

python -m unittest discover -s tools -p 'test_*.py'
Ran 174 tests ... OK

scripts/test_v2_voice_engine_banked.ps1
V2 voice engine simulation PASS

scripts/test_v2_voice_banked.ps1
tb_v2_voice_replay PASS rows=1827 samples=1784 ram=0 tolerance=1LSB
tb_v2_voice_replay PASS rows=1827 samples=1784 ram=1 tolerance=1LSB

git diff --check
```

The replay covers deterministic released/oldest/velocity/voice-ID selection,
bounded steal-release, pending activation, revoice, ADSR, detune, vibrato,
saturation, all-notes-off, scan-boundary backpressure and both portable and
GW5A DPB state-bank models. The fresh command
`scripts/run_gowin_cli.ps1 -TclScript scripts/synth_v2_voice_engine_banked_20261026.tcl`
against this post-fix source exits with code 1 before `gw_sh.exe` emits Tcl
output. Therefore the 2026-10-26 routed voice artifacts and their Fmax/slack
values are retained as historical evidence only; they do not close the current
source's 100 MHz P&R gate. Final V2 top timing and board evidence remain open.
