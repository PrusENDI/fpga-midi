---
name: gowin-plan-driven-rtl
description: >
  Use when a multi-day RTL effort must follow a written plan on a Gowin FPGA:
  each task needs a failing test, synthesised numbers, and committed evidence
  before the next one starts. Symptoms this prevents: "the modules all pass but
  nothing runs on the board", "Fmax is fine" without a P&R report, register
  arrays that synthesise to zero BSRAM and half the expected Fmax, timing
  closure attempted by lowering the clock. Keywords: Gowin, gw_sh, tcl,
  synthesis, place and route, Fmax, slack, DPB, SDPB, BSRAM, timing closure.
---

# Plan-driven RTL on Gowin

## Core principle

**A task is done when a report says so, not when the RTL compiles.**

Estimates, intentions, and "it simulates" are not evidence. Every claim maps to
an artefact: a log line, a report field, or a measurement.

## The task loop

Run these in order for one plan task. Do not start the next task until step 7.

```text
1. Read the plan entry: Files, Interfaces, Steps, Stop gate, As-built status
2. Write the failing check first (Python reference vector or SV testbench)
3. Run it; confirm the failure names the missing implementation
4. Implement the smallest RTL that satisfies the check
5. Simulate in ModelSim; compare against the reference frame by frame
6. Synthesise the module alone; record LUT / FF / DSP / BSRAM
7. Integrate to the top, place and route, read the report
8. Update the plan's as-built row and the validation report
9. Commit code and documents together, evidence in the message
```

Step 2 is not optional. RTL written before its check has no acceptance
criterion, and the missing criterion reappears as a rewrite two tasks later.

## Evidence table

| Claim | Required artefact |
| --- | --- |
| Module behaves correctly | ModelSim log plus a frame-by-frame match against the reference |
| Timing closes | P&R report: actual Fmax, setup/hold TNS, violated endpoint count = 0 |
| Resources fit | Synthesis report: LUT, FF, DSP, BSRAM actual counts |
| Latency meets target | Scope or GPIO capture at the board |
| Shippable | Bitstream file plus its SHA-256 |

A number that came from arithmetic rather than a tool is a plan, not a result.
Write it as an estimate.

## Timing escalation ladder

Apply in this order. Each step buys nanoseconds; the last one costs capability.

```text
1. Pipeline the long path        (split one combinational block into two registers)
2. Narrow the datapath          (24 bits where 32 were used)
3. Convert to a multi-cycle FSM (a slow path may take 2-8 cycles)
4. Replace index-muxed arrays with explicit RAM primitives
5. Reduce parallelism           (fewer multipliers or adders in one cycle)
6. Lower the clock              (recompute the per-sample cycle budget afterwards)
```

Step 6 shrinks the cycles available per sample, so it forces a reduction in
voices or effects. Report that consequence; do not hide it.

## Gowin traps

### Register array instead of RAM

```systemverilog
logic [31:0] phase [0:31];
phase[slot] <= next_phase;      // variable index
```

Expected: 0 BSRAM, large FF count, Fmax roughly halved (measured 58 MHz against
100 MHz on this board). Fix: instantiate a `DPB` (dual port) or `SDPB` block,
drive the address, accept one cycle of synchronous read latency.

### Q16.16 does not map to DSP

The 18x18 multipliers are integer units. Fractional arithmetic compiles to a
long carry chain in fabric. Fix: multiply integers and shift afterwards, or
instantiate the DSP primitive explicitly.

### SDPB and DPB differ

`DPB` allows simultaneous read and write on 16-bit lanes; wide data must be
split across lanes. `SDPB` is single port and needs a cycle between write and
read. Choosing the wrong one produces RTL that simulates and fails on hardware.

### Clocking

50 MHz board clock through the PLL to 100 MHz, and the 48 kHz sample enable
from a fractional accumulator (2083.33 cycles per sample, so a plain divider
drifts). Keep one clock domain: slow front-end logic uses multi-cycle FSMs, not
a second free-running clock.

## Report fields to read

| Field | Why |
| --- | --- |
| Actual Fmax | The only timing number that matters |
| Setup / hold TNS | Total negative slack; must be 0 |
| Violated endpoints | Count, and which path |
| Logic / FF / DSP / BSRAM | Fit against the device, with margin |
| PLL count | Confirms the clock plan |

Quote the constrained frequency only alongside the actual one; alone it says
nothing.

## Monorepo conventions

```text
scripts/synth_<module>_<date>.tcl   one script per task, four sections:
                                    device, files, constraints, run syn + pnr
scripts/run_gowin_cli.ps1           CLI entry: licence, working directory,
                                    exit code
```

Record the command, the script path, the output directory, and the exit code
next to every reported number.

## Rationalizations

| Excuse | Reality |
| --- | --- |
| "Synthesis passed, timing is fine" | Synthesis is not P&R. Only P&R reports Fmax. |
| "It will close once the top is wired" | Wiring adds load. Measure after wiring. |
| "The estimate is close enough" | Estimates become the story. Label them. |
| "Simulation matches, hardware will too" | Port width, RAM port behaviour, and clock edge differ. |
| "The test would pass anyway" | Then it takes a minute. Run it. |
| "No time for a testbench" | The rewrite takes longer than the testbench. |

## Red flags

- A timing number with no report path beside it.
- A module reported done while its plan row still lists differences.
- Arrays indexed by a register that synthesise to zero BSRAM.
- Frequency lowered before the pipeline steps were tried.
- Commits that change RTL without touching the as-built row.

## Common mistakes

| Mistake | Correction |
| --- | --- |
| One giant synthesis run per day | One script per task, so a failure points at one module |
| Reporting the constraint as the result | Report actual Fmax and slack |
| Committing simulation output | Ignore simulator directories; keep the scripts |
| Deleting failed probe scripts | Keep the final probe, drop the intermediate variants |
