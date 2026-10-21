# PC Host XYZ Filtering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic PC-only MGC3130 coordinate-quality, Z→XY decoupling, filtering, and fixed-PitchSpace integration path for Capture & Loop.

**Architecture:** Keep raw capture immutable and add a focused `host_xyz_filter` module that turns raw reports into quality-marked, decoupled, filtered frames. `synthwave_loop` consumes those frames before landmark extraction and note generation; the receiver and Tk UI expose quality and 3D projections without generating live notes. Profile construction is explicit and replayable, never learned during ordinary Lead recording.

**Tech Stack:** Python 3 standard library, existing dependency-free compiler and Tkinter UI, existing Microchip GestIC C++ receiver, `unittest`, JSON/JSONL/CSV replay files.

**Spec:** `docs/pc-host-only-xyz-filtering-design-2026-10-21.md`, `docs/mgc3130-coordinate-calibration-spec.md`, `docs/pc-lead-intent-purification-design-2026-10-19.md`

## Global Constraints

- Preserve raw XYZ, timestamps, validity, error, saturation, and sequence-gap information; never overwrite raw capture.
- Use a fixed `HostCalibrationProfile`; ordinary Lead recording must not update it.
- Fit Z→XY coupling only from explicit depth-only calibration captures using robust binned medians and residuals.
- Do not interpolate across invalid frames, long gaps, or saturated regions.
- Pure Z motion must not create new Lead pitches; Z may still modulate expression parameters.
- Fixed PitchSpace and register boundaries must not be rebuilt from one take's min/max or start point.
- Capture & Loop remains offline for note generation; recording UI may preview filtered coordinates but must not emit live NOTE_ON events.
- Do not add a separate musical test set; use deterministic unit cases plus existing real captures for replay checks.

---

### Task 1: Define profile and filtered-frame data contracts

**Files:**
- Create: `tools/host_xyz_filter.py`
- Test: `tools/test_host_xyz_filter.py`

**Interfaces:**
- Produces `HostCalibrationProfile`, `FilterConfig`, `QualityFlags`, `FilteredCapture`, `build_identity_profile()`, and JSON serialization helpers.
- `HostCalibrationProfile` must include profile id/hash, raw reference, workspace bounds, fixed axes, pitch bounds, saturation bounds, neutral MAD, coupling bins, timestamp units, and filter parameters.
- `FilteredCapture` must retain every accepted input frame plus `q_raw`, `q_decoupled`, `q_filtered`, `b_abs`, `c_abs`, `coupling_alpha`, quality flags, motion state, and diagnostics.

- [ ] **Step 1: Write failing contract tests** for profile round-trip, identity profile behavior, tri-state quality fields, and preservation of unknown input fields.
- [ ] **Step 2: Run** `python -m unittest tools.test_host_xyz_filter -v`; confirm the new types/functions are missing.
- [ ] **Step 3: Implement** immutable dataclasses, stable profile hashing, `to_dict/from_dict`, and an identity profile that performs no coupling correction while explicitly reporting zero coupling confidence.
- [ ] **Step 4: Run** the focused tests and then `python -m unittest discover -s tools -p 'test_*.py'`.

### Task 2: Implement profile estimation from explicit calibration captures

**Files:**
- Modify: `tools/host_xyz_filter.py`
- Create: `tools/build_host_profile.py`
- Test: `tools/test_host_xyz_filter.py`

**Interfaces:**
- `estimate_neutral(samples) -> NeutralEstimate`
- `fit_z_coupling(depth_samples, reference_z, bin_count=7) -> CouplingModel`
- `estimate_workspace(samples, neutral) -> WorkspaceEstimate`
- `build_profile(neutral_samples, depth_samples, workspace_samples, metadata) -> (HostCalibrationProfile, diagnostics)`

- [ ] **Step 1: Add failing tests** for median/MAD neutral estimation, seven-bin piecewise-median coupling, sparse-bin confidence reduction, and fixed workspace bounds.
- [ ] **Step 2: Run** the focused tests and confirm failures.
- [ ] **Step 3: Implement** explicit-capture-only profile estimation; save bin sample counts, residual scales, profile hash, and timestamp units. Reject empty or invalid calibration captures with readable errors.
- [ ] **Step 4: Implement CLI** accepting `--neutral`, `--depth`, `--workspace`, `--out`, and optional `--profile-id`; emit JSON profile plus diagnostics.
- [ ] **Step 5: Run** the CLI against existing `calibration/session_0010_center_static`, `session_0013_z`, and workspace captures; inspect residuals without treating the result as final hardware calibration.

### Task 3: Implement quality masking, decoupling, filtering, and motion states

**Files:**
- Modify: `tools/host_xyz_filter.py`
- Test: `tools/test_host_xyz_filter.py`

**Interfaces:**
- `filter_capture(samples, profile) -> FilteredCapture`
- `apply_z_coupling(frame, profile) -> frame`
- `classify_motion(previous, current, profile) -> str`

- [ ] **Step 1: Add failing tests** for saturation, invalid frames, sequence gaps, pure-Z suppression, diagonal-motion preservation, impulse removal, dynamic low-pass timing, slew limiting, and no interpolation across invalid spans.
- [ ] **Step 2: Implement** quality mask first; mark `INVALID/LOST` and split segments on invalid, saturation, or long gaps.
- [ ] **Step 3: Implement** binned piecewise-linear Z coupling with confidence-weighted `alpha`; retain raw coordinates and correction reasons.
- [ ] **Step 4: Implement** time-based median (15–30 ms), dynamic first-order low-pass (35–60 ms), and profile slew limits; use logical time, never spatial X, for ordering.
- [ ] **Step 5: Implement** `DEPTH_ONLY`, `PITCH_INTENT`, `DIAGONAL_INTENT`, `TREMOR`, `HOLD`, and `INVALID/LOST` classification with dead-zone and minimum-duration thresholds.
- [ ] **Step 6: Run** focused and full Python tests.

### Task 4: Integrate the host filter into Lead compilation

**Files:**
- Modify: `tools/synthwave_loop.py`
- Modify: `tools/test_synthwave_loop.py`

**Interfaces:**
- Extend `preprocess_samples(..., host_profile=None)` and `compile_lead(..., host_profile=None)` while preserving current callers.
- `compile_loop(..., host_profile=None)` must pass the same profile to Lead and include profile hash and filter diagnostics in the result.

- [ ] **Step 1: Add failing integration tests** proving the same pure-Z capture produces no extra pitch changes after filtering, diagonal intent remains directional, fixed PitchSpace is unchanged, and repeated compilation is byte-equivalent.
- [ ] **Step 2: Replace direct raw projection** with the filtered `b_abs/c_abs` path when a host profile is provided; keep identity behavior for legacy/default callers.
- [ ] **Step 3: Correct pitch hysteresis units** so hysteresis is expressed in fixed pitch-space units rather than comparing MIDI semitones to a normalized constant.
- [ ] **Step 4: Propagate motion state, confidence, coupling alpha, invalid/rest reasons, and source-frame ranges into landmarks and EventTable diagnostics.
- [ ] **Step 5: Run** `python -m unittest tools.test_synthwave_loop -v` and the complete existing test suite.

### Task 5: Add replay and diagnostic CLI

**Files:**
- Create: `tools/replay_host_filter.py`
- Test: `tools/test_replay_host_filter.py`

**Interfaces:**
- CLI accepts JSONL/CSV capture, profile JSON, optional output prefix, and emits filtered JSONL, diagnostics JSON, and compiled EventTable when requested.

- [ ] **Step 1: Add failing tests** for deterministic replay, profile hash mismatch reporting, and output preservation of raw fields.
- [ ] **Step 2: Implement** replay without random state or implicit profile learning; report `profile_hash`, `capture_hash`, quality counts, and motion-state counts.
- [ ] **Step 3: Run** replay on `tools/capture_fast_01.csv`, `tools/capture_fast_02.csv`, and existing calibration sessions; compare before/after pitch-coordinate variance and event sequences.

### Task 6: Extend the SDK receiver quality schema

**Files:**
- Modify: `pc_receiver/mgc3130_receiver.cpp`
- Modify: `pc_receiver/test_pc_receiver.py`
- Modify: `pc_receiver/README.md`

**Interfaces:**
- JSONL position records add `sequence`, `timestamp_raw`, `logical_time_ms`, `position_valid`, `xyz_valid`, `report_error`, `clipping`, `environmental_noise`, `calibration_reason`, and `sequence_gap` where the SDK exposes them.
- Fields unavailable through the public SDK result structure must be `null` with a `quality_known` marker; the receiver must never infer a valid position from a repeated XYZ sample.

- [ ] **Step 1: Add fixture tests** for the extended schema and tri-state quality handling.
- [ ] **Step 2: Implement receiver-side sequence and logical-time bookkeeping, calibration event export, and explicit unknown quality fields where required by the SDK API.
- [ ] **Step 3: Build the existing Win32 receiver project and run the receiver contract tests.

### Task 7: Add profile selection and 3D diagnostics to the Tk UI

**Files:**
- Modify: `pc_receiver/synthwave_ui.py`
- Modify: `pc_receiver/test_pc_receiver.py` if UI-independent helpers are extracted

**Interfaces:**
- UI loads/saves a profile JSON, displays profile status/hash, and passes the selected profile to offline compile.
- UI renders raw/decoupled/filtered XY, XZ, YZ projections plus pitch/depth/time traces; invalid spans are visibly broken.

- [ ] **Step 1: Add profile load/save controls and a raw/filtered display toggle without changing event generation.
- [ ] **Step 2: Add synchronized XY/XZ/YZ/time canvases and state/quality indicators.
- [ ] **Step 3: Show fixed PitchSpace grid, quantized note, source landmark, coupling alpha, and correction reason.
- [ ] **Step 4: Verify recording remains Capture & Loop: filtered preview only during recording, full compile only after Stop.

### Task 8: Real-capture acceptance and documentation update

**Files:**
- Modify: `docs/pc-host-only-xyz-filtering-design-2026-10-21.md`
- Modify: `docs/mgc3130-coordinate-calibration-spec.md`
- Create: `mgc3130_uart/artifacts/host_filter_replay_report.json` (generated report only)

- [ ] **Step 1: Run the existing real captures through the profile and replay tools.
- [ ] **Step 2: Verify pure-Z pitch variance reduction, preserved intentional direction, explicit invalid gaps, stable fixed-register mapping, and deterministic EventTables.
- [ ] **Step 3: Record residual limitations and the selected profile hash; do not call the host profile hardware calibration.
- [ ] **Step 4: Run the complete Python test suite and preserve command/output summaries in the report.

