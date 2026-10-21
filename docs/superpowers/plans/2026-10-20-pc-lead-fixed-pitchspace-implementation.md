# Fixed PitchSpace and Lead Sound Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Implement the PC Capture & Loop reference path described by sections 13–14: fixed three-dimensional gesture space, deterministic Lead compilation, and Neon Ambient Lead rendering.

**Architecture:** Keep the JSONL receiver as the sensor boundary. Replace the legacy Lead compiler inside `tools/synthwave_loop.py` with a dependency-free pipeline: calibration/profile projection → time resampling → open-path features → landmark state machine → fixed PitchSpace quantization → Lead EventTable. Keep non-Lead tracks touch/tap driven. Add a deterministic LeadPatch renderer and expose diagnostics in the existing Tk UI.

**Tech Stack:** Python 3.10+, standard library only for the core/compiler/UI, Tkinter UI, unittest, WAV PCM rendering.

**Spec:** `mgc3130_uart/docs/pc-lead-intent-purification-design-2026-10-19.md` sections 13–14 and `mgc3130_uart/docs/mgc3130-coordinate-calibration-spec.md`.

## Global Constraints

- Capture & Loop only: no live note triggering.
- Time stamps are the only rhythmic order; never sort samples by X.
- Default mode is fixed Absolute Workspace; per-capture min/max and 5%/95% scaling are diagnostics only.
- Default PitchSpace is A minor pentatonic, G3–C5, register locked.
- Every Lead note must reference a landmark; no unconditional generated climax or tonic.
- Z/depth may change same-register color and articulation but cannot cause octave jumps.
- Compiler output must be deterministic for identical capture/profile/config/seed.
- Non-Lead events remain user-triggered and are never derived from the Lead.

---

### Task 1: Add fixed profiles and deterministic preprocessing

**Files:**
- Modify: `mgc3130_uart/tools/synthwave_loop.py`
- Test: `mgc3130_uart/tools/test_synthwave_loop.py`

**Interfaces:**
- Add frozen dataclasses `CalibrationProfile`, `PitchSpace`, and `LeadPatchProfile`.
- Add `DEFAULT_CALIBRATION`, `DEFAULT_PITCH_SPACE`, and `DEFAULT_LEAD_PATCH`.
- Add `project_sample(sample, calibration, mode="workspace") -> dict`.
- Add `preprocess_samples(samples, calibration) -> list[dict]`.

- [x] Write tests for fixed profile values, absolute pitch projection, and timestamp ordering.
- [x] Run `python -m unittest tools.test_synthwave_loop -v` and verify new tests fail before implementation.
- [x] Implement affine XYZ projection `q_app = S*R*(XYZ-offset)`, fixed `q_ref`, fixed workspace bounds, 5-frame median/Hampel filtering, and deterministic low-pass.
- [x] Ensure preprocessing reports `out_of_range` and never uses capture min/max to define pitch.
- [x] Run the focused tests and verify they pass.

### Task 2: Implement open-path features and landmark extraction

**Files:**
- Modify: `mgc3130_uart/tools/synthwave_loop.py`
- Test: `mgc3130_uart/tools/test_synthwave_loop.py`

**Interfaces:**
- Add `extract_landmarks(projected_samples, style=STYLE) -> list[dict]`.
- Add `resample_to_ticks(samples, style=STYLE) -> list[dict]`.
- Add `OpenPathFeatures` or equivalent serializable feature fields: `tau`, `a_rel`, `b_abs`, `c_abs`, `speed`, `curvature`, `state`.

- [x] Write tests for timestamp order, HOLD on a stationary segment, TURN on a direction reversal, and explicit REST on invalid/away samples.
- [x] Run focused tests and verify failure.
- [x] Implement timestamp-based 128-tick resampling, local smoothing, finite differences, fixed-axis Workspace features, and optional Gesture-Aligned rotation without changing the fixed pitch origin.
- [x] Implement MOVE/HOLD/TURN/APEX/VALLEY/REST/RELEASE landmark generation with hysteresis constants from the spec.
- [x] Run focused tests and verify pass.

### Task 3: Compile deterministic Lead events in fixed PitchSpace

**Files:**
- Modify: `mgc3130_uart/tools/synthwave_loop.py`
- Test: `mgc3130_uart/tools/test_synthwave_loop.py`

**Interfaces:**
- Add `compile_lead(samples, style=STYLE, calibration=DEFAULT_CALIBRATION, pitch_space=DEFAULT_PITCH_SPACE, mode="workspace") -> dict`.
- Keep `compile_loop(...)` as the public six-track entry point and route its Lead through `compile_lead`.
- Add event fields: `source_landmarks`, `raw_target_midi`, `target_scale_index`, `quantization_delta`, `register_id`, `color_layer`, `out_of_range`, `articulation`, `glide_ms`, `accent`, `release_tail`, `generated_reason`.

- [x] Write tests for fixed octave/range, quantization hysteresis, no Z-driven octave jump, no unconditional climax/tonic, deterministic replay, and every note having landmark sources.
- [x] Run focused tests and verify failure.
- [x] Implement fixed scale table quantization, chord-aware same-register color exceptions, Direct/Polished modes, explicit REST events, and conservative note density.
- [x] Implement diagnostics: mode/profile hashes, capture hash, landmark counts, coverage, insufficient-capture/weak-motif status, and no-source count.
- [x] Run focused tests and verify pass.

### Task 4: Implement Neon Ambient Lead rendering

**Files:**
- Modify: `mgc3130_uart/tools/synthwave_loop.py`
- Test: `mgc3130_uart/tools/test_synthwave_loop.py`

**Interfaces:**
- `render_loop(result, output, sample_rate=22050, loops=1) -> Path` remains stable.
- Add deterministic oscillator/filter/envelope helpers driven by `LeadPatchProfile`.
- Preserve existing simple rendering for non-Lead tracks while applying Lead mono/legato, glide, accent, cutoff modulation, chorus/delay/reverb send.

- [x] Write tests that render a non-empty WAV, applies LeadPatch metadata, and remains deterministic for the same event table.
- [x] Run focused tests and verify failure.
- [x] Implement band-limited-enough saw/pulse approximation, mono/legato phase continuity, ADSR/release tails, chorus/delay/reverb-like deterministic buses, and hard output limiting.
- [x] Run focused tests and verify pass.

### Task 5: Expose PitchSpace and landmark diagnostics in the Tk UI

**Files:**
- Modify: `mgc3130_uart/pc_receiver/synthwave_ui.py`
- Test: `mgc3130_uart/pc_receiver/test_pc_receiver.py` (only non-GUI helper assertions if needed)

**Interfaces:**
- Add visible mode selector for Workspace/Gesture-Aligned.
- Add PitchSpace labels and compiler diagnostics in the status/log/tree.
- Draw fixed pitch grid and projected path/landmarks without normalizing canvas to capture min/max.
- Keep Record/Stop/Compile/Preview/Import/Export workflow unchanged.

- [x] Add UI-level helper methods that can be tested without opening a window.
- [x] Run receiver contract tests and focused compiler tests.
- [x] Implement mode and profile display, fixed pitch grid labels, landmark coloring, and event source/quantization columns.
- [x] Run focused compiler, receiver, and capture-loop tests. Full discovery still has two pre-existing package-import failures when launched from the repository root.

### Task 6: Update PC receiver documentation and verification artifacts

**Files:**
- Modify: `mgc3130_uart/pc_receiver/README.md`
- Create: `mgc3130_uart/docs/superpowers/plans/2026-10-20-pc-lead-fixed-pitchspace-implementation.md` (this plan)
- Modify: `mgc3130_uart/docs/pc-lead-intent-purification-design-2026-10-19.md` only if implementation constraints require a clarification.

- [x] Document offline replay, fixed profile selection, Direct/Polished, and WAV/Event JSON outputs.
- [ ] Run `python -m unittest discover -s . -p 'test*.py' -v` from `mgc3130_uart` (blocked by existing tests that import sibling modules without package paths).
- [x] Run a fixture compile and inspect event JSON diagnostics and generated WAV size.
- [x] Report any missing optional audio dependencies separately; core path must remain dependency-free.

---


