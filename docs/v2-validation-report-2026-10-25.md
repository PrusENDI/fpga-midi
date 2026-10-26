# V2 validation status

Updated: 2026-10-26. This is an in-progress evidence record, not a final acceptance report.
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

## Gate audit

Initial scoped reviews accepted code fixes without enforcing all plan evidence gates.
Those completion claims are superseded by this audit. Tasks 6–12 have not started.

| Task | Implementation / evidence | Gate status |
| --- | --- | --- |
| 1 contract | Corrections `097ff47`, `fe3ab72`, `4325d2f` add four indexed parameter families, concrete CSR/access/op/ACK/event definitions, signed two's-complement writes, Python/SV Q/scope/range metadata parity, and runnable SV width/layout assertions with mutation checks. | Contract/codec gate accepted by independent scoped review. Downstream RTL consumers and Task5 constant imports remain later gates. |
| 2 clock | Corrections `dfbf4ae`, `e18a68d` use GW5A `PLLA`: 50 MHz / 1 × 1 × 20 / 10 = 100 MHz. Manufacturer-model lock/reset/relock, injected unlock, two-edge reset release and 10 ns period tests pass. Scheduler counted 48,000 enables in 100,000,000 cycles with 2083/2084 intervals. Clock/scheduler/reset probe P&R: Fmax 194.654 MHz, setup/hold TNS 0, PLLA 1/6. | Clock/scheduler gate accepted after scoped independent review. I2S output constraints require the actual V2 transmitter/top ports at Task 12. This probe does not establish whole-design timing. |
| 3 input | Corrected latch → calibration → validity replay covers 976 frames, including signed17 X/Y, unsigned17 Z, gaps, saturation and invalid metadata; focused Python and ModelSim suites pass. | Accepted for its scoped gate; no whole-design timing claim. |
| 4 cursor | Integrated 976-row latch → calibration → validity → cursor replay, 12 Python tests, ModelSim pass, and standalone synthesis evidence. | Accepted for its scoped gate; no whole-design timing claim. |
| 5 rules | Separate LIVE/LOOP rule engines with backpressure, left-edge/rightward confirmation, reverse rejection and six-track recorder; Python and ModelSim suites pass. | Accepted for its scoped gate. |
| 6–7 loop/Potts | Six-track two-bank store/scheduler transaction replay passes; bounded Potts DP replay and backpressure pass. | Accepted for scoped gates; remaining coverage and device-level cycle timing are residuals. |
| 8 voices | 32-slot two-oscillator lifecycle, 33rd overflow, release, revoice phase preservation, detune, ADSR, saturation, valid/ready and round-robin tests pass; explicit 240-bit/15-lane DPB state bank is synthesized and routed. | **Accepted for the scoped Task 8 gate:** fresh 100 MHz routed probe reports Fmax 101.832 MHz, setup/hold TNS 0, zero violated endpoints and +0.180 ns worst setup slack. Full V2 top and board timing remain Task 12 evidence. |
| 9–12 | Wavetable/FX, UART/telemetry, UI and independent V2 top remain downstream. | Not started because Task 8 timing Stop gate is blocked. |

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
4. `V2_SIM` bypass has no frequency multiplication. Testbenches using it must drive a
   100 MHz simulated system clock. The hardware primitive path is tested separately
   with the actual 50 MHz board clock.

## Final claims intentionally pending

No final V2 top bitstream, board revision/capture, trigger-to-waveform latency, FX
level or whole-design timing has been accepted. Task 8 is accepted only for its
standalone voice-engine gate. No board was programmed during this work. The routed
voice probe cannot establish timing for calibration, cursor, FX or the final top.


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

Task 6 adds independent `v2_loop_event_store` and `v2_loop_scheduler` RTL. The
store uses two banks, six tracks, sixteen 96-bit slots per track, explicit
shadow commit at `loop_boundary`, and abort/overflow metadata. The scheduler
uses held ready/valid events and STOP/FLUSH cancellation. These modules compile
with ModelSim. The joint `sim/tb_v2_loop_transactions.sv` replay now passes with
real store-to-scheduler wiring: shadow prepare/write, boundary bank swap,
six-track active read, three-pass NOTE_ON scan with held output under
backpressure, a pass-gated duration-derived NOTE_OFF, and abort preserving the
active bank. The duration vector is checked at its end tick so it cannot be
re-emitted by the ON or CONTROL passes. This is RTL simulation evidence only;
no P&R or timing claim is made.
Task 7 Potts commit evidence: the standalone fixed-point commit FSM and Python
reference cover a 128-tick contour, A-minor pentatonic candidates, minimum
segment length, rest masking, bounded event RAM, backtrace-valid completion,
and held output backpressure. The measurement script reports the observed RTL
cycle count; the 41 us design figure remains an estimate until a device-level
timing run.

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
