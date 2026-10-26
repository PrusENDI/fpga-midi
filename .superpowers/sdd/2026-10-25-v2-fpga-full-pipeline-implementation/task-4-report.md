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

Result: `GowinSynthesis finish`, generated `impl/v2_cursor_synth/impl/gwsynthesis/v2_cursor_syn.rpt.html` and netlist. The current post-review resource report records 947 registers, 692 ALUs, 10,613 LUTs, and 14 DSPs for `v2_cursor_filter`. (The intermediate post-review report before stable-point storage recorded 10,220 LUTs; this report uses the final rerun.) No P&R/Fmax claim is made; this was standalone synthesis only.

## Verification limits / concerns

- The RTL and Python reference are independently exercised; no full RTL/Python bit-for-bit replay harness is claimed.
- Gowin synthesis log reports only unused `calibration_reason[7]` and `[4]` inputs; ModelSim is clean. The Q16 products use explicit 64-bit temporaries for the IIR, depth, and slew paths.
- The standalone synthesis output is ignored under `impl/`; no generated report was added to the commit.
- No event-rule engine is changed here, so the stop-gate property is represented by cursor semantics: a rebase frame is zero-displacement and `DEGRADED`/`REBASED` are explicit for downstream event gating.

`git diff --check` was run on the task files before commit.


## Review blocker fixes (2026-10-26)

Fixed in follow-up commit `fix: close cursor filter review blockers`:

1. Full-window median now uses `{current, hist[0], hist[1], hist[2], hist[3]}` after startup. History shifts newest-to-oldest, so the previous implementation incorrectly discarded the newest prior sample (`hist[0]`). Added a six-sample changing-X vector that distinguishes latest-five from stale-window behavior.
2. Added stable cursor/control/sequence/timestamp registers. `sample_ce` now snapshots that stable record; high-Z freeze, REBASED, invalid, and degraded frames cannot publish new audio metadata/control points. REBASED clears `stable_valid` until the next ordinary engaged point. Python's `_latest_stable` regression covers the same behavior.
3. Normalized pitch is assigned from the computed next cursor Y, avoiding the old-cursor nonblocking-assignment lag. Q16.16 values saturate to `16'hffff` at the 16-bit output boundary. RTL/Python tests cover both next-value pitch and saturation.
4. RTL velocity includes the Python reference slew-speed term: `base + proximity term + 3/16 * min(speed,Q16_ONE)`. Independent `frame_degraded` input is a bad frame and cannot update filter state. Changing-frame vectors assert the expected 62976 Q16 control.

Review verification:

```text
python -m unittest tools.test_v2_cursor_reference -v
Ran 12 tests ... OK

C:\modeltech64_10.6d\win64\vlog.exe -sv rtl/v2_input_pkg.sv rtl/v2_cursor_filter.sv sim/tb_v2_cursor_filter.sv
C:\modeltech64_10.6d\win64\vsim.exe -c -do "run -all; quit -f" tb_v2_cursor_filter
# tb_v2_cursor_filter PASS; vlog errors 0

git diff --check HEAD^ HEAD -- <task files>
# no whitespace errors
```

Final standalone Gowin rerun: `GowinSynthesis finish`; HTML resource report is 947 registers, 692 ALUs, 10,613 LUTs, and 14 DSPs. The synthesis log contains only unused `calibration_reason[7]` and `[4]` warnings. No P&R/Fmax claim is made.
