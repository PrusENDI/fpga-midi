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
| 3 input | Calibration/validity and latch extension; eight focused Python tests and ModelSim assertions. | Open: unsigned sensor boundary correction, integer/reason RTL-reference replay and arithmetic synthesis required. |
| 4 cursor | Twelve Python tests, ModelSim assertions, standalone synthesis: 947 registers, 692 ALUs, 10,613 LUTs, 14 DSPs for revision `6a6821c`. | Open: exact RTL-reference replay and integration with corrected sensor coordinates required. No 100 MHz timing claim for this module. |
| 5 rules | Candidate `97e5808`: separate LIVE and LOOP modules, six Python tests and two RTL smoke tests. | Not accepted: final review and backpressure, arm/rightward-motion, note-spacing corrections required. |
| 6–12 | No accepted six-track bank transactions, Potts, 32-voice engine, wavetable/FX, UART, UI or V2 integration yet. | Not started. |

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

No final V2 bitstream, board revision/capture, trigger-to-waveform latency, 32-voice
operation, Potts cycle budget, FX level or whole-design timing has been accepted.
No board was programmed during this work. The clock-only routed probe cannot establish
timing for calibration, cursor, voice, FX or the final top.


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
