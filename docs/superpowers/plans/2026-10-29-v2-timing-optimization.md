# V2 FPGA Timing and Resource Optimization Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the real GW5A final-top resource and 100 MHz timing gates while preserving the V2 reader, LIVE/LOOP, real Potts, 32×2 voice, nonzero reduced FX, UART telemetry, and I2S path needed for board acceptance.

**Architecture:** Keep the portable/reference Potts contract at its existing 128-point default. A Loop spans 128 musical ticks independently of its 32 event slots per track; a 32-point board horizon requires an explicit, verified full-loop contour and output-time mapping. That mapping is not yet implemented. Reduce logic and timing through registered multi-cycle boundaries in Potts, voice metadata allocation, and front-end control paths; do not close a gate by disabling a required path or relying on a swept preserve net. Every structural change is checked with ModelSim first and then a fresh `gw_sh` synthesis/P&R in a new output directory.

**Tech Stack:** SystemVerilog RTL, Gowin V1.9.12.04 `gw_sh`, ModelSim 10.6d, PowerShell, Python `unittest`, GW5A-LV25MG121NES, and the existing verified wrapper `scripts/run_gowin_cli.ps1`.

**Spec:** `docs/superpowers/plans/2026-10-25-v2-fpga-full-pipeline-implementation.md` and `docs/v2-fpga-contract-2026-10-25.md`.

## Current Audit Amendment (2026-10-29)

Read `docs/v2-design-progress-gap-audit-2026-10-29.md` before resuming this
plan. It supersedes historical current-status statements and the old assumption
that 32 event slots justify a 32-tick contour. Existing unchecked steps below
remain the original acceptance criteria, not a completion percentage.

H0 is implemented and has run successfully. A+B is integrated at `338435c`;
clean run `clean_baseline_1` records **12,787 logic, 68.013 MHz, 3,125 setup
violations, -7,704.703 ns TNS, zero hold violations, CLS 85%, 36 BSRAM and
16 DSP sites**. E2/5 and CPU/SSPI regular IO are correct. The verifier still
blocks NL0002/setup and incorrectly parses the 100 MHz constraint as actual
Fmax. This resource-legal diagnostic run does not close Task 5.

Before final timing acceptance, close the audit's functional gates: musical
transport and full-loop H32 mapping, contour/rest semantics, Potts writeback
before atomic shadow publication, continued active playback, CSR/STOP/APPLY,
UART frame ownership, parameter consumers and I2S format/constraints. These
are requirements of the full design, not optional timing improvements.

The latest critical path is Potts event control to voice DPB write data through
note/delta logic (18 levels, 14.773 ns). Fix the commit dataflow before accepting
optimizations to that route; use fresh reports to choose subsequent paths.
Both cell depth and routing matter. Task 1's sweep support must be introduced
as a shared versioned harness/profile extension, not separate worker forks.

## Global Constraints

- The final top path must retain valid sensor input, actual MGC3130 reader or an equivalent reachable input, LIVE/LOOP, a non-empty recorder contour, real Potts, 32 simultaneous voices × 2 oscillators, nonzero reduced FX, actual UART/telemetry TX, and I2S.
- The board clock is the 50 MHz oscillator at E2/5. The Tcl flow must set `-use_sspi_as_gpio 1` and `-use_cpu_as_gpio 1`; final reports must contain neither PR2017 nor PR2028.
- The final timing gate is a fresh current-source P&R at 100 MHz with no setup or hold violations. A probe, stub, `USE_POTTS=0`, constant contour, or swept preserve net is diagnostic evidence only.
- Portable Potts behavior remains `HORIZON=128` by default. A board build may use `POTTS_HORIZON=32` only when the full 128-tick contour-to-32-point mapping and inverse event tick/duration mapping are covered by RTL tests and recorded in the validation report. The 32 event slots per track do not define the time horizon.
- The fixed voice acceptance target remains 32 voices × 2 oscillators. Reducing voice count, disabling FX, or changing the clock to 80 MHz is a separately reviewed fallback and cannot be reported as the 100 MHz pass.
- Each independently verified change gets a local Git commit and an entry in `docs/v2-progress-log.md`; generated `impl/` and simulator work directories remain untracked.

## Parallel Workstream Amendment (2026-10-29)

This amendment makes the execution split explicit. It supersedes any task-level
file ownership that would let the two workers create different full-path
harnesses.

The operational split and handoff contract are maintained in
`docs/parallel/v2-ab-parallel-execution-plan.md`; the B-specific dsh handoff is
`docs/parallel/dsh-project-b-handoff.md` and its copyable prompt is
`docs/parallel/dsh-project-b-prompt.txt`.

### Shared H0 harness gate

Before either repair stream starts, the main integration lane creates and
commits one canonical harness consisting of:

- `sim/v2_top_fullpath_probe.sv`
- `scripts/synth_v2_top_fullpath_20261029.tcl`
- `scripts/verify_v2_fullpath_run.ps1`
- the harness section of `docs/v2-progress-log.md`

That commit is the shared H0 base. Both worktrees must cherry-pick the exact
same H0 commit before making stream-specific edits. The harness fixes the
device, source-file list, top parameters, E2 constraints, wrapper command,
fresh output-directory rule, manifest fields, and report checks. A worker may
run the harness but may not fork or silently edit it.

The two workers use these worktrees and branches:

| Stream | Worktree | Branch | Allowed implementation area |
| --- | --- | --- | --- |
| A — voice timing | `.worktrees/v2-voice-timing` | `work/v2-voice-timing` | banked voice metadata/state and voice tests |
| B — Potts/resource | `.worktrees/v2-potts-resource` | `work/v2-potts-resource` | Potts RTL/tests and resource/P&R evidence |

Both workers invoke the same wrapper and Tcl from their own worktree. They use
different `impl/<run-id>/` directories. ModelSim jobs may run concurrently;
license-bound Gowin synthesis/P&R jobs are serialized if the license server
offers only one seat. Neither worker edits `docs/v2-progress-log.md`; each
writes a stream report, and the main lane merges the reports after review.

### Stream A — voice metadata timing repair

The A worker owns only Task 2 files and may consume the shared H0 harness for
post-change evidence. It must not modify Potts RTL, the full-path Tcl, the
shared verifier, or Stream B files. Its independent gate is functional voice
regression plus an improved reported voice critical path.

### Stream B — Potts and resource closure

The B worker owns Task 1 and Task 3 implementation files and may consume the
shared H0 harness for controlled H32/H128 and FX sweeps. It must not modify
voice RTL, Stream A tests, the shared verifier, or the main progress ledger.
Its independent gate is unchanged Potts event behavior plus resource usage
below the GW5A limit; full-path timing is recorded but is not declared final
until the main lane integrates both streams.

### Integration gate after A/B

The main lane reviews both diffs, runs the shared harness from the merged
commit in a new output directory, updates the progress ledger, and only then
starts Task 4 and the final P&R/board gates. A stream commit that changes the
shared harness is rejected or split into a separately reviewed H0 fix.

## Baseline Evidence (2026-10-29)

- `scripts/test_v2_top_potts.ps1`: PASS.
- `scripts/test_v2_top.ps1`: PASS.
- `python -m unittest discover -s tools -p 'test_*.py'`: 175 tests, OK.
- `git diff --check`: exit 0; only line-ending warnings are present.
- Fresh full-path run with `USE_MGC_READER=1`, `USE_POTTS=1`, `PRESERVE_LOOP_PLANE=1`, `PRESERVE_POTTS_PLANE=1`, `POTTS_HORIZON=32`, `FX_ENABLE=1`, and `FX_LEVEL=1` reaches synthesis but fails `RP0006`: 25,538 logic (21,610 LUT + 3,928 ALU) against the 23,040 GW5A limit. No new routed netlist or bitstream exists for this run.
- The last package-legal routed artifact is older diagnostic evidence: 21,513 logic, 5,966 registers, 33 DPB, 15 DSP, Fmax 2.616 MHz, 2,383 setup violations, TNS -19,983.029 ns, zero hold violations. Its report places `clk_50m` at E2/5 and its `device.cfg` has both CPU and SSPI `regular_io = true`; it is not board-programmable acceptance evidence.

### Task 0 / H0: Freeze the Shared Reproducible Full-Path Harness

**Files:**
- Create: `sim/v2_top_fullpath_probe.sv`
- Create: `scripts/synth_v2_top_fullpath_20261029.tcl`
- Create: `scripts/verify_v2_fullpath_run.ps1`
- Modify: `scripts/run_gowin_cli.ps1` only if a wrapper diagnostic is needed; preserve its existing invocation contract
- Modify: `docs/v2-progress-log.md`

**Interfaces:**
- Consumes `rtl/mgc3130_v2_top.sv`, `mgc3130_v2.cst`, and `mgc3130_v2_top_observable.sdc`.
- Produces a named top that explicitly sets `USE_MGC_READER=1`, `USE_GOWIN_RAM=1`, `USE_POTTS=1`, `PRESERVE_LOOP_PLANE=1`, `PRESERVE_POTTS_PLANE=1`, `POTTS_HORIZON=32`, `FX_ENABLE=1`, and `FX_LEVEL=1`.

- [ ] Add the full-path probe as a separate source so the resource-legal diagnostic probe remains available for comparison.
- [ ] Add a Tcl manifest that writes to a unique `impl/v2_top_fullpath_<run-id>` directory, opens the GW5A-LV25MG121NES project, enables both E2 regular-IO options, runs `syn` and `pnr`, and exits nonzero on tool failure. Refuse to reuse an existing run directory.
- [ ] Run the exact command below from the repository root and retain the logs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path `
  -LicenseServer 106.55.34.119:10559 `
  -RunId h0_baseline_20261029
```

- [ ] Require the wrapper manifest and run `scripts/verify_v2_fullpath_run.ps1 -RunDir impl/v2_top_fullpath_h0_baseline_20261029` to record the source commit, tool exit code, top parameter string, `RP0006` result, `device.cfg`, and whether P&R produced a new report.
- [ ] Commit the harness as H0, then cherry-pick that exact commit into both A and B worktrees before any optimization edit.

### Task 1: Attribute Logic and Timing by Controlled Sweeps

**Files:**
- Create: `scripts/sweep_v2_fullpath_resources.ps1`
- Create: `docs/v2-fullpath-resource-baseline-2026-10-29.md`

**Interfaces:**
- Consumes the Task 0 probe and wrapper.
- Produces a table for H128/H32, FX level 0/1, and each voice/Potts optimization candidate with logic, register, DPB, DSP, Fmax, setup TNS, hold TNS, and error codes.

- [ ] Run one fresh synthesis per variant through the shared H0 Tcl in a unique `impl/` directory; never overwrite the retained baseline or edit the H0 files in this stream.
- [ ] Reject any variant that removes a required path, reports `NL0002 swept`, or changes the 32×2 voice contract.
- [ ] Set the pre-timing resource target to at most 22,000 logic, leaving at least 1,040 logic cells for P&R variation.
- [ ] Commit the sweep script and measured table.

### Task 2: Repair the Banked Voice Metadata Critical Path

**Files:**
- Modify: `rtl/v2_voice_engine_banked.sv`
- Modify: `rtl/v2_voice_state_bank.sv` only when the explicit read/write latency boundary requires it
- Modify: `sim/tb_v2_voice_engine_banked.sv` and/or `sim/tb_v2_voice_replay.sv` for latency-aware assertions
- Create: `docs/parallel/v2-voice-timing-report.md`

**Interfaces:**
- Consumes the existing NOTE_ON/OFF/REVOICE contract and `sample_ce` boundary.
- Produces the same 32-bit active bitmap, voice-steal counter, release/revoice behavior, two-oscillator sample, and vibrato readback with explicit registered metadata stages.

- [ ] Add or strengthen a failing assertion for the current victim-selection and bounded-release timing before changing RTL.
- [ ] Pipeline `age`, `releasing`, and `velocity` reads so scan, victim selection, state-bank read, oscillator compute, and writeback do not share one long combinational path.
- [ ] Preserve deterministic priority: released, oldest, lowest velocity, lowest voice ID; preserve one pending-note mailbox and bounded steal-release.
- [ ] Run `scripts/test_v2_voice_engine_banked.ps1`, `scripts/test_v2_voice_banked.ps1`, `python -m unittest discover -s tools -p 'test_*.py'`, and `git diff --check`.
- [ ] Run the standalone voice Gowin probe and the Task 0 full-path synthesis. Accept the change only when functional evidence is unchanged and the reported worst voice path improves.
- [ ] Use the shared H0 harness without changing its files; write stream evidence to a voice-specific report for the main lane.
- [ ] Commit the RTL and evidence.

### Task 3: Reduce Potts Logic Without Changing Events

**Files:**
- Modify: `rtl/v2_potts_commit_fsm.sv`
- Modify: `sim/tb_v2_potts_commit_fsm.sv` and `sim/tb_mgc3130_v2_top_potts.sv`
- Modify: `scripts/test_v2_top_potts.ps1`
- Create: `docs/v2-potts-h32-resource-note-2026-10-29.md`
- Create: `docs/parallel/v2-potts-resource-report.md`

**Interfaces:**
- Consumes the 128-point contour input and 128-bit rest mask.
- Produces the same 96-bit event stream, backtrace, event count, overflow, progress, and completion semantics; `HORIZON=128` remains the default. `HORIZON=32` is currently a diagnostic board profile and requires explicit full-128-tick contour/output mapping before semantic acceptance; event-slot capacity alone is not such a mapping.

- [ ] Add a reference-vector assertion covering H32 and H128 event equivalence on the shared first 32 points.
- [ ] Independently verify the full 128-tick board mapping (including ticks 32–127 and output durations); shared-prefix equivalence alone does not close the board semantic gate.
- [ ] Replace implementation-wide `integer` arithmetic or repeated wide operations only with explicitly sized fixed-point intermediates; keep saturated cost and tie-breaking behavior unchanged.
- [ ] Ensure the FSM remains multi-cycle and never blocks `sample_ce`, UART status reads, or active-bank playback.
- [ ] Run the Potts top regression and Python reference tests before synthesis.
- [ ] Run the full-path synthesis and require logic usage to decrease without an `NL0002 swept` message.
- [ ] Use the shared H0 harness without changing its files; write stream evidence to a Potts/resource-specific report for the main lane.
- [ ] Commit the smallest accepted change and record the measured busy interval and resource delta.

### Task 4: Shorten Front-End, FX, and Telemetry Control Paths

**Files:**
- Modify only the path identified by the Task 1/2/3 reports, chosen from `rtl/v2_input_calibration.sv`, `rtl/v2_cursor_filter_timed.sv`, `rtl/v2_live_rule_engine.sv`, `rtl/v2_fx_lite.sv`, `rtl/v2_telemetry_snapshot.sv`, and `rtl/mgc3130_v2_top.sv`
- Modify the matching `sim/` testbench and `scripts/test_*.ps1`
- Modify: `docs/v2-progress-log.md`

**Interfaces:**
- Preserves `sample_ce`, 48 kHz I2S cadence, telemetry `ready/valid`, ACK priority, nonzero reduced FX, and all V2 CSR layouts.

- [ ] Select the actual worst path from the fresh report; do not pipeline unrelated code by guesswork.
- [ ] Insert explicit register/FIFO boundaries at the selected path and add a latency assertion at the consumer.
- [ ] Re-run the top, FX/wavetable, UART/telemetry, and audio smoke gates.
- [ ] Re-run Task 0 full-path P&R and record setup/hold/Fmax and any new resource cost.
- [ ] Commit only after the measured path and functional contract both improve or remain unchanged.

### Task 5: Final 100 MHz P&R Gate

**Files:**
- Modify: `scripts/synth_v2_top_fullpath_20261029.tcl` only for reproducibility fixes
- Create: `docs/v2-final-top-pnr-2026-10-29.md`
- Modify: `docs/v2-board-readiness-review-2026-10-28.md` and `docs/v2-validation-report-2026-10-25.md`

- [ ] Start from a clean source commit and a new `impl/v2_top_fullpath_<commit-or-date>` directory.
- [ ] Run the verified wrapper with the license server and retain synthesis, P&R, timing, power, pin, `device.cfg`, and bitstream outputs.
- [ ] Check the report for logic ≤23,040, no `RP0006`, no `NL0002`, no PR2017/PR2028, E2/5 clock placement, CPU/SSPI `regular_io = true`, zero setup violations, zero hold violations, and a 10 ns 100 MHz requirement met.
- [ ] Hash the newly generated `.fs` only after every preceding condition passes.
- [ ] If the design is resource-legal but still below 100 MHz after at least one real front-end/voice/Potts pipeline repair, record the failure and open the plan's separate 80 MHz fallback review; do not silently change the primary acceptance frequency.
- [ ] Commit the report and progress entry.

### Task 6: Board-Readiness and Measurement Gate

**Files:**
- Create: `scripts/measure_v2_latency.ps1` if it does not already exist
- Create: `impl/v2_top_fullpath_<accepted-run>/README.md`
- Modify: `docs/v2-validation-report-2026-10-25.md`
- Modify: `docs/v2-board-readiness-review-2026-10-28.md`

- [ ] Program only the timing-passing bitstream.
- [ ] Capture UART at 1 Mbaud and 115200 baud, including ACK/NACK and 22-byte telemetry frames.
- [ ] Capture I2S BCLK/LRCK/DIN cadence and sample count, check underrun/fault status, and measure trigger-to-waveform latency.
- [ ] Record board revision, exact bitstream hash, tool version, constraints, measured values, and every acceptance item as pass/fail.
- [ ] Mark the project ready for board acceptance only when the source, P&R, protocol, I2S, and board evidence all agree.

## Completion Checklist

- [ ] The full-path source is reproducible from one commit with a named Tcl script.
- [ ] Resource usage is below the GW5A logic limit with headroom and no swept required path.
- [ ] The voice metadata critical path and any remaining front-end/Potts path meet the 100 MHz timing requirement.
- [ ] Potts H32 board behavior is covered while the portable H128 default remains intact.
- [ ] CPU/SSPI regular-IO settings, E2/5 placement, UART telemetry, nonzero FX, and I2S are present in the same final top evidence.
- [ ] Only the timing-passing bitstream is hashed and offered for programming.
- [ ] Progress log, validation report, and board-readiness review contain the exact commands, revisions, reports, hashes, and measured board data.
