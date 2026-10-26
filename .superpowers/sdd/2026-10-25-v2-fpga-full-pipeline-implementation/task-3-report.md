# Task 3 report — V2 input validity and fixed-point calibration

## Implementation

- Added `rtl/v2_input_pkg.sv` with the packed raw input frame contract and reason bits.
- Added `rtl/v2_input_calibration.sv` implementing the frozen order: signed raw extension, neutral subtraction, Q16.16 Z coupling subtraction, rounded gain, workspace clamp, and quality output. Shadow profile writes become active only on `profile_commit`; active epoch mismatches are invalid.
- Added `rtl/v2_position_validity.sv` for sequence gap accounting, invalid/saturated/epoch masking, degraded/lost diagnostics, and `note_permitted`. Invalid, lost, saturated, or epoch-mismatched frames cannot be note-permitted.
- Extended `rtl/mgc3130_input_latch.sv` with V2 raw frame outputs while preserving all legacy ports and pulse behavior. Existing touch-only and invalid report clearing semantics remain intact.
- Added deterministic Python reference (`tools/v2_fixed_reference.py`), focused tests, and neutral/depth/workspace/invalid/saturation/gap vectors under `tools/testdata/v2_input/`.
- Added `sim/tb_v2_input_validity.sv` covering sign extension, profile activation, workspace clamp, saturation rejection, and sequence gap loss.

## RED/GREEN evidence

RED: `python -m unittest tools.test_v2_fixed_reference -v` failed before implementation with `ModuleNotFoundError: tools.v2_fixed_reference`.

GREEN: `python -m unittest tools.test_v2_fixed_reference tools.test_v2_input_vectors -v` — 5 tests passed.

GREEN: ModelSim `C:\modeltech64_10.6d\win64\vlog.exe` compiled the V2 package, calibration, validity, and testbench with 0 errors; `vsim` reported `tb_v2_input_validity PASS`.

`git diff --check` completed without whitespace errors for task files.

## Synthesis

No standalone Gowin arithmetic synthesis was run because the repository has no frozen V2 arithmetic project/device mapping; the prior task's board declaration reports no PLL resource for its selected device. LUT/FF/DSP utilization is therefore not claimed.

## Concerns

- `sequence` is a SystemVerilog keyword in ModelSim, so the packed frame field is named `frame_sequence` and module ports use `sequence_id` while retaining the documented meaning.
- The V1 latch has no SDK presence/calibration epoch inputs; its V2 presence is derived from successful XYZ reports and epoch defaults to zero. A reader/top-level integration can drive a real epoch later without changing legacy behavior.
- The calibration output is registered; consumers should use the corresponding output pulse and pass the same frame metadata to `v2_position_validity`.
