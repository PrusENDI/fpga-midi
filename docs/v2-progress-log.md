# V2 FPGA implementation progress log

This file records reproducible implementation checkpoints. Generated
`impl/`, ModelSim work libraries, transcripts and local captures remain outside
Git; source, tests, scripts and evidence summaries are committed.

## 2026-10-29 — fresh E2 board P&R and timing checkpoint

The verified Gowin wrapper was rerun with license-server access against the
current `eb87408` source:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 \
  -TclScript (Resolve-Path scripts/synth_v2_top_board_20261026.tcl).Path \
  -LicenseServer 106.55.34.119:10559
```

The run entered Tcl, passed synthesis and completed placement, routing, timing,
power analysis and bitstream generation (`V2_TOP_BOARD_PNR_PASS`, exit 0).
The fresh report is under `impl/v2_top_board_20261026/impl/pnr/` for device
`GW5A-LV25MG121NES`; `mgc3130_v2.cst` is loaded and `clk_50m` is constrained at
**E2/5**. The generated `device.cfg` now contains both `SSPI regular_io = true`
and `CPU regular_io = true`; the previous PR2017/PR2028 errors are absent.
The bitstream is
`impl/v2_top_board_20261026/impl/pnr/v2_top_board.fs` (7,250,286 bytes) with
SHA-256
`8F3741A3F14F31F6E0002983B75B860DF0C53CDD95B93B23285CC899D9EF9129`.

This is a current-source, package-legal board artifact, but it is **not** a
timing pass. The report uses the generated 100 MHz PLL clock and records actual
Fmax **2.615 MHz**, **3,151** setup-violated endpoints, setup TNS
**-211686.406 ns**, and zero hold violations. Resource usage is 18,043 logic,
2,936 registers, 33 DPB, 1 DSP and 10 I/O ports. The worst paths are through
the banked voice `age`/`steal_hold` RAMREG structures (about -372 ns slack), so
the artifact must not be programmed as a final V2 image. The next phase is a
structural voice-state timing repair followed by a fresh full-path P&R.

Fresh functional gates after the run remain green: `scripts/test_v2_top.ps1`,
`scripts/test_v2_patch_bank.ps1`, `scripts/test_v2_wavetable_fx.ps1`, and the
Python suite (`175 tests`).

## 2026-10-29 — telemetry TX and nonzero FX checkpoint

Commit `6960501` closes the top telemetry consumer boundary. ACK/NACK response
bytes retain priority; the double-buffered telemetry snapshot now sees
`frame_ready` only when the physical UART is idle, and the top regression checks
SOF plus byte advancement under 1 Mbaud backpressure. The same commit adds
build-time FX parameters and enables reduced FX level 1 in the board probe, so
the P&R manifest cannot silently sweep the FX block. `scripts/test_v2_top.ps1`
passes with the new telemetry check.

The fresh E2 P&R still completes package placement and bitstream generation with
CPU/SSPI regular IO and `clk_50m` at E2/5, but the nonzero FX path raises usage to
21,513 logic (94%), 5,966 registers, 33 DPB and 15 DSP. Actual Fmax is **2.616
MHz**, setup violations **2383**, setup TNS **-19983.029 ns**, and hold
violations **0**. Bitstream SHA-256 is
`00FC2C478387315515DBCB207529946304663B4936102E50E8C628D444FE7649`.
This remains diagnostic timing evidence; resource headroom and voice metadata
timing must be resolved before any board programming.

## 2026-10-29 — voice metadata timing reduction checkpoint

Commit `e9c0486` replaces the per-voice bounded-release countdown RAMREG array
with one scalar countdown paired with the registered victim slot. The voice
engine and replay gates pass for both portable and GW5A DPB models. A fresh E2
rerun remains package-legal and generates a bitstream, while timing improves to
actual Fmax **3.072 MHz**, setup violations **1977**, setup TNS
**-18635.975 ns**, hold violations **0**, with 16,329 logic, 2,440 registers,
33 DPB and 1 DSP. The remaining critical path is the 32-way `age` metadata
priority result driving `releasing` write enables (about -315 ns worst slack).
This is still timing-failure evidence and must not be programmed.

## 2026-10-28 — lightweight long-run workflow checkpoint

Added the repository-local explicit skill
`.codex/skills/fpga-long-run/SKILL.md` (commit `9275223`). It keeps ordinary
documentation, audits and single-command checks on a short checkpoint path;
full `subagent-driven-development` is reserved for multi-file RTL/interface
changes, timing closure or repeated unresolved failures. The skill requires
fresh evidence for each gate, records source revision and bitstream hash, and
preserves the existing no-reset/no-clean recovery rule.

The E2 board-clock constraint is now documented and configured in the legacy
and V2 board P&R Tcl entry points: both `-use_sspi_as_gpio 1` and
`-use_cpu_as_gpio 1` are required because E2 is shared by CPU/SSPI. An E2 P&R
result is still pending; the earlier E1 audio-smoke result remains the only
package-legal clock evidence.

The Top CSR phase now instantiates the patch bank and wavetable loader and
routs PATCH/WT selector, data, CRC, APPLY, status, version and synchronous read
responses through the V2 UART boundary. Fresh gates pass:
`scripts/test_v2_top.ps1`, `scripts/test_v2_patch_bank.ps1`,
`scripts/test_v2_wavetable_fx.ps1`, and the Python suite (`175 tests`). The top
smoke covers patch shadow readback and incomplete APPLY errors, plus WT selector
metadata, partial-upload status and incomplete APPLY errors. Complete WT active
sample readback remains covered by the standalone 1024-sample gate; final top
FX enable, telemetry TX and current-source P&R remain open.

The V2 board P&R Tcl manifest now includes the patch/wavetable RTL and both E2
regular-IO overrides. A fresh `gw_sh` invocation returned exit code 1 without
console output and left the retained P&R files dated 2026-10-26; their old
`device.cfg` still says `CPU regular_io = false`. No new E2 package result is
claimed until the CLI produces a refreshed report with both CPU and SSPI set to
regular IO.

## 2026-10-28 — pre-Task-8.5 checkpoint

The V2 contract is frozen for 32-slot/two-bank Loop storage, 16-bit voice-steal
diagnostics, N-tone selectors, wavetable selection fields and vibrato readback.
The Loop recorder/store/scheduler path has 32 slots per track, explicit DPB and
boundary timeout coverage. Potts now consumes the real recorder contour in the
top simulation; the measured busy interval is 1,868,573 simulation-domain
cycles for the current eight-event contour. The audio smoke slice covers the
fractional 48 kHz cadence and I2S framing.

The banked voice engine now provides 32 slots × two oscillators, a 256-bit
state-bank word, deterministic released/oldest/velocity/voice-ID stealing,
bounded eight-pass release, pending-note activation, revoice glide and UQ8.8
vibrato. The release path was corrected so the hold counter follows the
compute-stage slot and the envelope cannot wrap below zero.

Reproducible checks completed at this checkpoint:

```text
python -m unittest tools.test_v2_voice_vectors -v       # 8 passed
python -m unittest discover -s tools -p 'test_*.py'     # 174 passed
scripts/test_v2_voice_engine_banked.ps1                 # PASS
scripts/test_v2_voice_banked.ps1                        # PASS, 1827/1784, RAM=0/1
git diff --check                                      # PASS
```

The current-source Gowin voice P&R rerun exits before Tcl output with code 1;
the older 2026-10-26 routed artifact is therefore historical evidence only.
The next active work item is Task 8.5's independent N-tone test mode, followed
by the remaining Task 9–12 integration and full-path timing/board gates.

## 2026-10-28 — Task 9 and Task 8.5 checkpoint

Task 9 now has two direct-current-source ModelSim scripts:
`scripts/test_v2_patch_bank.ps1` and `scripts/test_v2_wavetable_fx.ps1`.
They pass the patch upload/CRC/range/atomic-APPLY checks and the wavetable/FX
incomplete-table, boundary-APPLY, active-readback, saturation and nonzero
reduced-FX checks. These are standalone gates; final top FX/patch CSR wiring and
board I2S evidence remain open.

Task 8.5 now has an independent `v2_test_mode` with selector-1 N-tone control,
1–32 tone counts, phase reset, active bitmap, sample counter, fault readback and
fixed 220 Hz × k sine tones. `scripts/test_v2_test_mode.ps1` generates N=1, 2,
4, 8, 16 and 32 captures; `tools/test_v2_spectrum.py` reports all expected
peaks within 1 Hz for the current fixed-point capture. The checker now runs a
4096-sample Hann-window radix-2 FFT and rejects sideband ratio above 0.02; the
current six captures measure 0.0026–0.0090. This mode remains isolated from EventTable/LIVE/LOOP; the top now
routes TEST_SELECT_0 through UART read/write and bypasses FX to I2S while the
test mode is active. The top smoke checks readback, I2S sample-valid and zero
voice allocation.

The Task 9 and Task 8.5 validation commits are kept separate from the initial
checkpoint so each gate can be reverted or reviewed independently.

## 2026-10-28 — Task 8.5 top integration and synthesis checkpoint

The final-top smoke path now includes `rtl/v2_test_mode.sv` in
`rtl/mgc3130_v2_top.sv`. A0 writes/reads are delivered through the existing V2
UART command boundary with a one-cycle delayed read response. Active test
samples bypass the currently disabled FX instance and drive the existing I2S
transmitter; LIVE/LOOP voice samples remain selected when test mode is idle.
`scripts/test_v2_top.ps1` passes the new N=1 readback/I2S/zero-voice checks and
the prior LIVE/LOOP smoke checks.

The standalone resource probe is reproducible with
`scripts/synth_v2_test_mode.tcl`. Synthesis passes and records 9,252 LUT,
782 ALU, 1,060 registers, 0 latch and 0 BSRAM. Its 158-port probe cannot be
placed on the GW5A package (PA2112/PA2024), so it is resource evidence only;
the final top timing and board gates remain open. All tracked
`scripts/synth_v2_top*.tcl` manifests now include `rtl/v2_test_mode.sv`, so a
future top synthesis cannot silently omit the newly instantiated module.

## 2026-10-28 — Task 12 status readback checkpoint

The top regression now reads `V2_CSR_STATUS` after a boundary commit and checks
the contract's `active_valid` bit. The response mux reports mode, active Loop
bank state and a combined protocol/recorder/timeout/test fault bit. This is a
small top CSR slice only; POSITION/DIAG/PATCH/WT/TLM readback, PLAY/RESET/STOP,
BPM timebase, telemetry TX and final top P&R/board evidence remain open.

The top smoke also now asserts the LIVE rule engine receives the actual
`degraded_frame` and `calibrated_gap` signals. The old constant-zero wiring was
removed; behavior-level invalid/gap vectors are still pending.

## Git publication note — 2026-10-28

The verified checkpoints are retained locally on `feat/loop-event-store`, with
the latest commit recorded by `git log`. A push to the configured `origin`
GitHub repository was attempted earlier and rejected by the environment's
automatic review because it is an external write to a public destination.
No bypass or repeated push was attempted; publication remains pending explicit
authorization for that repository.

## Git checkpoint policy

Create a commit after each independently verified task or a material root-cause
fix. Commit messages should identify the task and validation command. Push a
checkpoint when the remote is available; if the environment blocks network or
the remote rejects the push, keep the local commit hash and record the reason in
this file and the validation report.
