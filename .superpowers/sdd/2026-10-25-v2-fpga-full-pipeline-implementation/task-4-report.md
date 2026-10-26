# Task 4 report — V2 cursor filter, clutch/rebase, golden vectors

## Scope

Implemented the V2 cursor stage in the four task files:

- `rtl/v2_cursor_filter.sv`
- `sim/tb_v2_cursor_filter.sv`
- `tools/v2_cursor_reference.py`
- `tools/test_v2_cursor_reference.py`

The existing V1 RTL and pre-existing dirty user documents were not edited.

## Contract behavior

- Input-frame-rate causal five-sample median over calibrated XYZ, Q16.16 axis mapping and adaptive IIR (`alpha_low=0.12`, `alpha_high=1.0`, `z_low=4000`, `z_high=24000`).
- Per-frame Q16.16 slew limit (`MAX_STEP_Q16`, default 4096) and configurable `SETTLE_TICKS`.
- Hysteretic Z clutch: `z_release=36000` freezes the cursor and clears the hidden anchor; `z_engage=30000` re-engages.
- Initial engagement requires a left-edge indication (or mapped left edge). Re-engagement creates one `REBASED` frame with zero cursor displacement; the next frame returns to `ENGAGED`.
- `DISENGAGED`, `ENGAGED`, `REBASED`, and `DEGRADED` states are explicit. Invalid, saturated, gap, epoch/profile, or arithmetic-saturation reason bits do not update filter history, cursor, anchor, pitch, or stable point.
- Pure Z changes update depth/velocity controls without changing XY, normalized pitch, or cursor displacement.
- `sample_ce` only snapshots the latest stable point and preserves its sequence/timestamp; it never advances the input-frame filter or Loop timing.

## RED/GREEN evidence

RED before implementation:

```text
python -m unittest tools.test_v2_cursor_reference -v
ModuleNotFoundError: No module named 'tools.v2_cursor_reference'
```

GREEN Python:

```text
python -m unittest tools.test_v2_cursor_reference -v
Ran 8 tests ... OK
```

Covered vectors: no-left-edge initial arm, left-edge engagement, 5-point spike rejection, slew bound, high-Z freeze, one-frame rebase with no jump, settle ticks, invalid/gap/saturated/profile degradation, pure-Z pitch invariant, and latest-point sample_ce timestamp preservation.

GREEN ModelSim:

```text
C:\modeltech64_10.6d\win64\vlog.exe -sv rtl/v2_input_pkg.sv rtl/v2_cursor_filter.sv sim/tb_v2_cursor_filter.sv
C:\modeltech64_10.6d\win64\vsim.exe -c -do "run -all; quit -f" tb_v2_cursor_filter
```

Result: `tb_v2_cursor_filter PASS`, compile errors 0.

## Synthesis evidence

Ran the standalone Gowin synthesis project with absolute `gw_sh.exe`:

```text
C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe scripts/tmp_synth_v2_cursor.tcl
```

Result: `GowinSynthesis finish`, generated `impl/v2_cursor_synth/impl/gwsynthesis/v2_cursor_syn.rpt.html` and netlist. The resource report records 928 registers, 758 ALUs, 10,156 LUTs, and 13 DSPs for `v2_cursor_filter`. No P&R/Fmax claim is made; this was standalone synthesis only.

## Verification limits / concerns

- The RTL and Python reference are independently exercised; no full RTL/Python bit-for-bit replay harness is claimed.
- Gowin parser reports warnings for expression-width truncation in fixed-point arithmetic and unused `calibration_reason` bits 7 and 4; ModelSim is clean. The Q16 products use explicit 64-bit temporaries for the IIR, depth, and slew paths. A future integration review should decide whether to silence the remaining tool warnings with additional casts.
- The standalone synthesis output is ignored under `impl/`; no generated report was added to the commit.
- No event-rule engine is changed here, so the stop-gate property is represented by cursor semantics: a rebase frame is zero-displacement and `DEGRADED`/`REBASED` are explicit for downstream event gating.

`git diff --check` was run on the task files before commit.
